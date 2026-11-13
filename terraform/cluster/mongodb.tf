# MongoDB (ADR 0030): the Percona Operator runs a 3-member replica set, with
# Percona Backup for MongoDB writing daily backups and the oplog (PITR) to R2.
# Tsuru is the first user; each app user is declared in the CR below.
locals {
  mongodb_name      = "mongodb"
  mongodb_replset   = "rs0"
  mongodb_rs_host   = "${local.mongodb_name}-${local.mongodb_replset}.${local.mongodb_name}.svc.cluster.local"
  mongodb_r2_store  = "r2"
  mongodb_tsuru_uri = "mongodb://tsuru:${random_password.mongodb_tsuru.result}@${local.mongodb_rs_host}/tsuru?replicaSet=${local.mongodb_replset}&authSource=admin"
}

resource "kubernetes_namespace_v1" "mongodb" {
  metadata {
    name = local.mongodb_name
  }
}

resource "helm_release" "psmdb_operator" {
  name       = "psmdb-operator"
  namespace  = kubernetes_namespace_v1.mongodb.metadata[0].name
  repository = "https://percona.github.io/percona-helm-charts"
  chart      = "psmdb-operator"
  version    = var.psmdb_operator_chart_version

  values = [yamlencode({
    disableTelemetry = true
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    }
  })]
}

resource "cloudflare_r2_bucket" "mongodb" {
  account_id = var.cloudflare_account_id
  name       = var.mongodb_bucket
  location   = "weur"

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_account_token" "mongodb_backup" {
  account_id = var.cloudflare_account_id
  name       = "${local.infra.cluster_name}-mongodb"

  policies = [{
    effect = "allow"
    permission_groups = [{
      id = one(data.cloudflare_account_api_token_permission_groups_list.r2_object_write.result).id
    }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${cloudflare_r2_bucket.mongodb.name}" = "*"
    })
  }]
}

# Read by the pbm-agent sidecars, under the key names PBM expects.
resource "kubernetes_secret_v1" "mongodb_backup_r2" {
  metadata {
    name      = "mongodb-backup-r2"
    namespace = kubernetes_namespace_v1.mongodb.metadata[0].name
  }

  data = {
    AWS_ACCESS_KEY_ID     = cloudflare_account_token.mongodb_backup.id
    AWS_SECRET_ACCESS_KEY = sha256(cloudflare_account_token.mongodb_backup.value)
  }
}

# Application users. Alphanumeric only, so the password needs no escaping in
# a connection URI.
resource "random_password" "mongodb_tsuru" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "mongodb_users" {
  metadata {
    name      = "mongodb-app-users"
    namespace = kubernetes_namespace_v1.mongodb.metadata[0].name
  }

  data = {
    tsuru = random_password.mongodb_tsuru.result
  }

  lifecycle {
    # The operator annotates the Secret with each password's hash to notice
    # changes; removing it on every apply would be a permanent diff.
    ignore_changes = [metadata[0].annotations]
  }
}

resource "helm_release" "mongodb" {
  name       = local.mongodb_name
  namespace  = kubernetes_namespace_v1.mongodb.metadata[0].name
  repository = "https://percona.github.io/percona-helm-charts"
  chart      = "psmdb-db"
  version    = var.psmdb_db_chart_version

  values = [yamlencode({
    # The CR, its Services and the system-users Secret are all named after this.
    fullnameOverride = local.mongodb_name

    image = { repository = "percona/percona-server-mongodb", tag = var.psmdb_image_tag }
    # Versions are pinned here, not chosen by Percona's version service.
    upgradeOptions  = { apply = "disabled" }
    imagePullPolicy = "IfNotPresent"

    replsets = {
      (local.mongodb_replset) = {
        name     = local.mongodb_replset
        size     = 3
        affinity = { antiAffinityTopologyKey = "kubernetes.io/hostname" }
        # One member per location before any location gets a second.
        topologySpreadConstraints = [{
          maxSkew           = 1
          topologyKey       = "topology.kubernetes.io/zone"
          whenUnsatisfiable = "DoNotSchedule"
          labelSelector = {
            matchLabels = {
              "app.kubernetes.io/instance"  = local.mongodb_name
              "app.kubernetes.io/replset"   = local.mongodb_replset
              "app.kubernetes.io/component" = "mongod"
            }
          }
        }]
        annotations = {
          # A file copy of a running mongod isn't consistent; PBM backs it up.
          "backup.velero.io/backup-volumes-excludes" = "mongod-data"
        }
        podDisruptionBudget = { maxUnavailable = 1 }
        resources = {
          requests = { cpu = "200m", memory = "768Mi" }
          # null drops the chart's default CPU limit (throttling only hurts).
          limits = { cpu = null, memory = "1Gi" }
        }
        volumeSpec = {
          pvc = { resources = { requests = { storage = "10Gi" } } } # Hetzner's minimum
        }
        sidecars = [{
          name  = "mongodb-exporter"
          image = "percona/mongodb_exporter:${var.mongodb_exporter_version}"
          env = [
            {
              name      = "MONGODB_USER"
              valueFrom = { secretKeyRef = { name = "${local.mongodb_name}-secrets", key = "MONGODB_CLUSTER_MONITOR_USER" } }
            },
            {
              name      = "MONGODB_PASSWORD"
              valueFrom = { secretKeyRef = { name = "${local.mongodb_name}-secrets", key = "MONGODB_CLUSTER_MONITOR_PASSWORD" } }
            },
          ]
          args = [
            "--mongodb.uri=mongodb://localhost:27017/?authSource=admin",
            "--compatible-mode",
            "--collector.replicasetstatus",
          ]
          ports     = [{ name = "metrics", containerPort = 9216 }]
          resources = { requests = { cpu = "10m", memory = "32Mi" }, limits = { memory = "128Mi" } }
        }]
      }
    }

    sharding = { enabled = false }
    # otel-agent already ships every pod's logs (ADR 0029).
    logcollector = { enabled = false }

    backup = {
      enabled = true
      image   = { repository = "percona/percona-backup-mongodb", tag = var.pbm_image_tag }
      storages = {
        (local.mongodb_r2_store) = {
          main = true
          type = "s3"
          s3 = {
            bucket            = cloudflare_r2_bucket.mongodb.name
            prefix            = local.infra.cluster_name
            region            = "auto"
            endpointUrl       = "https://${local.r2_endpoint}"
            credentialsSecret = kubernetes_secret_v1.mongodb_backup_r2.metadata[0].name
          }
        }
      }
      # Oplog slices every 10 minutes on top of the daily base backup.
      pitr = { enabled = true, oplogSpanMin = 10, compressionType = "gzip" }
      tasks = [{
        name        = "daily"
        enabled     = true
        schedule    = "0 3 * * *" # 00:00 in São Paulo, after Velero, before kured's window
        type        = "logical"
        storageName = local.mongodb_r2_store
        retention   = { type = "count", count = 7, deleteFromStorage = true }
      }]
    }

    users = [{
      name              = "tsuru"
      db                = "admin"
      passwordSecretRef = { name = kubernetes_secret_v1.mongodb_users.metadata[0].name, key = "tsuru" }
      roles             = [{ name = "readWrite", db = "tsuru" }]
    }]
  })]

  depends_on = [helm_release.psmdb_operator]
}

resource "kubernetes_manifest" "mongodb_pod_monitor" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "mongodb"
      namespace = kubernetes_namespace_v1.mongodb.metadata[0].name
    }
    spec = {
      selector = {
        matchLabels = {
          "app.kubernetes.io/instance"  = local.mongodb_name
          "app.kubernetes.io/component" = "mongod"
        }
      }
      podMetricsEndpoints = [{ port = "metrics", interval = "30s" }]
    }
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_manifest" "mongodb_rules" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "mongodb"
      namespace = kubernetes_namespace_v1.mongodb.metadata[0].name
    }
    spec = {
      groups = [{
        name = "mongodb"
        rules = [
          {
            alert       = "MongodbMemberDown"
            expr        = "mongodb_up{namespace=\"${local.mongodb_name}\"} == 0"
            for         = "5m"
            labels      = { severity = "warning" }
            annotations = { summary = "MongoDB member {{ $labels.pod }} is down." }
          },
          {
            # myState 1 = PRIMARY. No member reporting it means no writes.
            alert       = "MongodbNoPrimary"
            expr        = "absent(mongodb_myState{namespace=\"${local.mongodb_name}\"} == 1)"
            for         = "2m"
            labels      = { severity = "critical" }
            annotations = { summary = "MongoDB replica set has no primary; writes are failing." }
          },
        ]
      }]
    }
  }

  depends_on = [helm_release.kube_prometheus_stack]
}
