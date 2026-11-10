# Harbor (ADR 0033): the registry Tsuru pushes to and nodes pull from. Its
# name is public but resolves to the private ingress LB, so nodes resolve it
# with Hetzner's DNS and only the private network and the tailnet reach it.
# Database from CloudNativePG, Redis from the Redis operator, blobs in R2.
locals {
  harbor_url = "https://${var.harbor_hostname}"
}

resource "kubernetes_namespace_v1" "harbor" {
  metadata {
    name = "harbor"
  }
}

# --- Database: charts/pg-cluster (ADR 0031) ---

resource "kubernetes_secret_v1" "harbor_db_r2" {
  metadata {
    name      = "harbor-db-r2"
    namespace = kubernetes_namespace_v1.harbor.metadata[0].name
  }

  data = {
    ACCESS_KEY_ID     = cloudflare_account_token.postgres_backup.id
    ACCESS_SECRET_KEY = sha256(cloudflare_account_token.postgres_backup.value)
  }
}

resource "helm_release" "harbor_db" {
  name      = "harbor-db"
  namespace = kubernetes_namespace_v1.harbor.metadata[0].name
  chart     = "${path.module}/charts/pg-cluster"

  values = [yamlencode({
    name     = "harbor-db"
    database = "registry"
    owner    = "harbor"
    # Harbor's core and exporter hold up to database.maxOpenConns each.
    parameters = { max_connections = "200" }
    backup = {
      bucket            = cloudflare_r2_bucket.postgres.name
      prefix            = local.infra.cluster_name
      endpointURL       = "https://${local.r2_endpoint}"
      credentialsSecret = kubernetes_secret_v1.harbor_db_r2.metadata[0].name
    }
  })]

  depends_on = [helm_release.cnpg_barman_plugin, helm_release.kube_prometheus_stack]
}

# --- Redis: a RedisReplication with Sentinel (ADR 0032) ---

resource "random_password" "harbor_redis" {
  length  = 32
  special = false
}

# Read by the operator (redisSecret); Harbor gets the same password below.
resource "kubernetes_secret_v1" "harbor_redis" {
  metadata {
    name      = "harbor-redis"
    namespace = kubernetes_namespace_v1.harbor.metadata[0].name
  }

  data = {
    REDIS_PASSWORD = random_password.harbor_redis.result
  }
}

resource "helm_release" "harbor_redis" {
  name       = "harbor-redis"
  namespace  = kubernetes_namespace_v1.harbor.metadata[0].name
  repository = "https://ot-container-kit.github.io/helm-charts"
  chart      = "redis-replication"
  version    = var.redis_replication_chart_version

  values = [yamlencode({
    redisReplication = {
      clusterSize = 2
      tag         = var.redis_image_tag
      redisSecret = { secretName = kubernetes_secret_v1.harbor_redis.metadata[0].name, secretKey = "REDIS_PASSWORD" }
      resources = {
        requests = { cpu = "20m", memory = "64Mi" }
        limits   = { memory = "256Mi" }
      }
    }
    sentinel = {
      enabled = true
      tag     = var.redis_image_tag
      size    = 3
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { memory = "128Mi" }
      }
    }
    # Cache, job queue and sessions: nothing worth a 10 GB volume per pod.
    storageSpec = null
    topologySpreadConstraints = [{
      maxSkew           = 1
      topologyKey       = "topology.kubernetes.io/zone"
      whenUnsatisfiable = "ScheduleAnyway"
      labelSelector     = { matchLabels = { app = "harbor-redis" } }
    }]
    pdb           = { enabled = true, minAvailable = 1 }
    redisExporter = { enabled = true, tag = var.redis_exporter_image_tag }
    serviceMonitor = {
      enabled   = true
      namespace = kubernetes_namespace_v1.harbor.metadata[0].name
    }
  })]

  depends_on = [helm_release.redis_operator, helm_release.kube_prometheus_stack]
}

# --- Registry storage in R2 ---

resource "cloudflare_r2_bucket" "harbor" {
  account_id = var.cloudflare_account_id
  name       = var.harbor_bucket
  location   = "weur"

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_account_token" "harbor" {
  account_id = var.cloudflare_account_id
  name       = "${local.infra.cluster_name}-harbor"

  policies = [{
    effect = "allow"
    permission_groups = [{
      id = one(data.cloudflare_account_api_token_permission_groups_list.r2_object_write.result).id
    }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${cloudflare_r2_bucket.harbor.name}" = "*"
    })
  }]
}

resource "kubernetes_secret_v1" "harbor_r2" {
  metadata {
    name      = "harbor-r2"
    namespace = kubernetes_namespace_v1.harbor.metadata[0].name
  }

  data = {
    REGISTRY_STORAGE_S3_ACCESSKEY = cloudflare_account_token.harbor.id
    REGISTRY_STORAGE_S3_SECRETKEY = sha256(cloudflare_account_token.harbor.value)
  }
}

# --- Harbor's own secrets, stable across upgrades ---

resource "random_password" "harbor_admin" {
  length  = 32
  special = false
}

# Encrypts credentials Harbor stores in its database; must be 16 characters.
resource "random_password" "harbor_secret_key" {
  length  = 16
  special = false
}

# core <-> registry basic auth. The htpasswd line uses the provider's stored
# bcrypt hash, so it doesn't change on every plan like bcrypt() would.
resource "random_password" "harbor_registry" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "harbor_secrets" {
  metadata {
    name      = "harbor-secrets"
    namespace = kubernetes_namespace_v1.harbor.metadata[0].name
  }

  data = {
    HARBOR_ADMIN_PASSWORD = random_password.harbor_admin.result
    secretKey             = random_password.harbor_secret_key.result
    REGISTRY_PASSWD       = random_password.harbor_registry.result
    REGISTRY_HTPASSWD     = "harbor_registry_user:${random_password.harbor_registry.bcrypt_hash}"
  }
}

resource "helm_release" "harbor" {
  name       = "harbor"
  namespace  = kubernetes_namespace_v1.harbor.metadata[0].name
  repository = "https://helm.goharbor.io"
  chart      = "harbor"
  version    = var.harbor_chart_version
  timeout    = 900 # first start runs the schema migrations

  values = [yamlencode({
    externalURL = local.harbor_url

    expose = {
      type = "ingress"
      tls = {
        enabled    = true
        certSource = "secret"
        secret     = { secretName = "harbor-tls" }
      }
      ingress = {
        hosts     = { core = var.harbor_hostname }
        className = "traefik"
        # null drops the chart's nginx annotations.
        annotations = {
          "ingress.kubernetes.io/ssl-redirect"          = null
          "ingress.kubernetes.io/proxy-body-size"       = null
          "nginx.ingress.kubernetes.io/ssl-redirect"    = null
          "nginx.ingress.kubernetes.io/proxy-body-size" = null
          # Private LB only (internal-apps.tf, ADR 0027).
          "traefik.ingress.kubernetes.io/router.entrypoints" = "internal"
          "traefik.ingress.kubernetes.io/router.tls"         = "true"
          "cert-manager.io/cluster-issuer"                   = "letsencrypt-prod"
          # A public record with the private LB's IP, not the public LB's IP
          # every Ingress status carries (ADR 0033).
          "external-dns.alpha.kubernetes.io/target" = local.infra.internal_ingress_ip
        }
      }
    }

    existingSecretAdminPassword    = kubernetes_secret_v1.harbor_secrets.metadata[0].name
    existingSecretAdminPasswordKey = "HARBOR_ADMIN_PASSWORD"
    existingSecretSecretKey        = kubernetes_secret_v1.harbor_secrets.metadata[0].name

    persistence = {
      enabled        = true
      resourcePolicy = "keep"
      persistentVolumeClaim = {
        # Hetzner's minimum; the vulnerability DB cache.
        trivy = { size = "10Gi" }
      }
      imageChartStorage = {
        type = "s3"
        # Clients pull through the registry, never from a presigned R2 URL.
        disableredirect = true
        s3 = {
          existingSecret = kubernetes_secret_v1.harbor_r2.metadata[0].name
          bucket         = cloudflare_r2_bucket.harbor.name
          region         = "auto"
          regionendpoint = "https://${local.r2_endpoint}"
          rootdirectory  = "/${local.infra.cluster_name}"
          secure         = true
          v4auth         = true
        }
      }
    }

    database = {
      type = "external"
      external = {
        host           = "harbor-db-rw"
        port           = "5432"
        username       = "harbor"
        coreDatabase   = "registry"
        existingSecret = "harbor-db-app" # created by CloudNativePG, key "password"
        sslmode        = "require"
      }
      maxIdleConns = 10
      maxOpenConns = 50
    }

    redis = {
      type = "external"
      external = {
        # Follows the primary: the operator relabels it after a Sentinel failover.
        addr = "harbor-redis-master:6379"
        # The password is set below. The chart writes it into its ConfigMaps
        # either way; existingSecret would only add a render-time lookup.
      }
    }

    portal = { image = { tag = var.harbor_version } }
    core   = { image = { tag = var.harbor_version } }
    jobservice = {
      image = { tag = var.harbor_version }
      # Job logs go to stdout (and Loki) instead of a 10 GB volume.
      jobLoggers = ["stdout"]
    }
    registry = {
      registry   = { image = { tag = var.harbor_version } }
      controller = { image = { tag = var.harbor_version } }
      credentials = {
        existingSecret = kubernetes_secret_v1.harbor_secrets.metadata[0].name
      }
    }
    trivy = {
      image = { tag = var.harbor_version }
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = null, memory = "1Gi" }
      }
      podAnnotations = {
        # The vulnerability DB is downloaded again if lost.
        "backup.velero.io/backup-volumes-excludes" = "data"
      }
    }
    exporter = { image = { tag = var.harbor_version } }
    nginx    = { image = { tag = var.harbor_version } }

    metrics = {
      enabled        = true
      serviceMonitor = { enabled = true }
    }
  })]

  lifecycle {
    precondition {
      # external-dns must publish it, and an internal-zone name would be
      # unresolvable on the nodes (they don't use the gateway's DNS).
      condition = (
        anytrue([for zone in var.external_dns_domains : endswith(var.harbor_hostname, ".${zone}")]) &&
        !endswith(var.harbor_hostname, ".${local.internal_domain}")
      )
      error_message = "harbor_hostname must be under one of external_dns_domains and outside infra's internal_domain."
    }
  }

  set_sensitive = [{
    name  = "redis.external.password"
    value = random_password.harbor_redis.result
  }]

  depends_on = [
    helm_release.harbor_db,
    helm_release.harbor_redis,
    helm_release.cluster_issuers,
    helm_release.kube_prometheus_stack,
  ]
}
