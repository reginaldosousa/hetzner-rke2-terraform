# Tsuru (ADR 0034, 0035): API, router and build agent, one chart each. Apps are
# internal (<app>.apps.<internal domain>, VPN only) until `tsuru cname add`
# gives them a public host (the mutation policy in internal-apps.tf). Created
# only once identity's tsuru_oidc and registry's tsuru_registry are set.
locals {
  tsuru_enabled     = var.tsuru_oidc != null && var.tsuru_registry != null
  tsuru_api_host    = "tsuru.${local.internal_domain}"
  tsuru_apps_domain = "apps.${local.internal_domain}"
  # Tsuru names app images <registry>/tsuru/app-<name>, so the registry is the
  # bare host and Harbor's tsuru project is the image namespace.
  tsuru_registry_host = local.tsuru_enabled ? var.tsuru_registry.server : ""
  # Internal-only routing for every Ingress the router creates (ADR 0027).
  tsuru_router_annotations = {
    "traefik.ingress.kubernetes.io/router.entrypoints" = "internal"
    "traefik.ingress.kubernetes.io/router.tls"         = "true"
  }
}

resource "kubernetes_namespace_v1" "tsuru" {
  count = local.tsuru_enabled ? 1 : 0

  metadata {
    name = "tsuru-system" # the charts' defaults assume this name
  }
}

# BuildKit runs privileged (it builds images with its own snapshotter), so it
# gets a namespace of its own as an explicit exception to the baseline
# (ADR 0018, 0034).
resource "kubernetes_namespace_v1" "tsuru_build" {
  count = local.tsuru_enabled ? 1 : 0

  metadata {
    name = "tsuru-build"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "random_password" "tsuru_router" {
  count = local.tsuru_enabled ? 1 : 0

  length  = 32
  special = false
}

# Expanded by Tsuru's config ($MONGODB_URL, $ROUTER_PASSWORD), so neither
# lands in its ConfigMap. The chart uppercases each key into the env name.
resource "kubernetes_secret_v1" "tsuru_api_env" {
  count = local.tsuru_enabled ? 1 : 0

  metadata {
    name      = "tsuru-api-env"
    namespace = kubernetes_namespace_v1.tsuru[0].metadata[0].name
  }

  data = {
    mongodb_url     = local.mongodb_tsuru_uri
    router_password = random_password.tsuru_router[0].result
  }
}

resource "helm_release" "tsuru_router" {
  count = local.tsuru_enabled ? 1 : 0

  name       = "kubernetes-router"
  namespace  = kubernetes_namespace_v1.tsuru[0].metadata[0].name
  repository = "https://tsuru.github.io/charts"
  chart      = "kubernetes-router"
  version    = var.tsuru_router_chart_version

  values = [yamlencode({
    image = { pullPolicy = "IfNotPresent" }
    # Only the API talks to it; the chart's default would buy a Hetzner LB.
    service         = { type = "ClusterIP" }
    controllerModes = ["ingress"]
    ingressExpose   = { domain = local.tsuru_apps_domain }
    arguments = concat(
      ["-ingress-class", "traefik", "-use-ingress-class-name=true"],
      flatten([for k, v in local.tsuru_router_annotations : ["-k8s-annotations", "${k}=${v}"]]),
    )
    api = { username = "tsuru" }
    resources = {
      requests = { cpu = "20m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    }
  })]

  set_sensitive = [{
    name  = "api.password"
    value = random_password.tsuru_router[0].result
  }]
}

resource "helm_release" "tsuru_deploy_agent" {
  count = local.tsuru_enabled ? 1 : 0

  name       = "deploy-agent"
  namespace  = kubernetes_namespace_v1.tsuru_build[0].metadata[0].name
  repository = "https://tsuru.github.io/charts"
  chart      = "deploy-agent"
  version    = var.tsuru_deploy_agent_chart_version

  values = [yamlencode({
    deployAgent = {
      image = { pullPolicy = "IfNotPresent" }
      resources = {
        requests = { cpu = "20m", memory = "64Mi" }
        limits   = { memory = "256Mi" }
      }
      # Push credentials for Harbor's tsuru project (terraform/registry).
      dockerConfig = jsonencode({
        auths = {
          (var.tsuru_registry.server) = {
            auth = base64encode("${var.tsuru_registry.username}:${var.tsuru_registry.password}")
          }
        }
      })
    }
    buildkit = {
      # The chart's default (v0.10) predates current Dockerfile features.
      image = { tag = var.buildkit_image_tag, pullPolicy = "IfNotPresent" }
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "2Gi" }
      }
    }
  })]
}

resource "helm_release" "tsuru_api" {
  count = local.tsuru_enabled ? 1 : 0

  name       = "tsuru-api"
  namespace  = kubernetes_namespace_v1.tsuru[0].metadata[0].name
  repository = "https://tsuru.github.io/charts"
  chart      = "tsuru-api"
  version    = var.tsuru_api_chart_version

  values = [yamlencode({
    image      = { pullPolicy = "IfNotPresent" }
    secretName = kubernetes_secret_v1.tsuru_api_env[0].metadata[0].name
    secretKeys = keys(kubernetes_secret_v1.tsuru_api_env[0].data)

    # TLS ends at Traefik; the API speaks HTTP behind it.
    service = { type = "ClusterIP", httpsOnly = false }
    ingress = {
      enabled          = true
      ingressClassName = "traefik"
      annotations      = local.tsuru_router_annotations
      hosts            = [{ host = local.tsuru_api_host, paths = [{ path = "/", pathType = "Prefix" }] }]
    }

    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "512Mi" }
    }

    tsuruConfig = {
      host   = "https://${local.tsuru_api_host}"
      useTLS = false
      debug  = false

      database = { mongodbURL = "$MONGODB_URL", databaseName = "tsuru" }
      queue    = { mongodbURL = "$MONGODB_URL", databaseName = "tsuru" }

      # Pocket ID first; native only for the break-glass root (ADR 0035).
      authBlock = {
        scheme            = "multi"
        user-registration = true
        multi             = { schemes = ["oidc", "native"], default-scheme = "oidc" }
        native            = { token-expire-days = 1, hash-cost = 12 }
        oidc = {
          client-id        = var.tsuru_oidc.client_id
          scopes           = ["openid", "email", "profile", "groups"]
          auth-url         = "${local.infra.oidc_issuer_url}/authorize"
          token-url        = "${local.infra.oidc_issuer_url}/api/oidc/token"
          jwks-url         = "${local.infra.oidc_issuer_url}/.well-known/jwks.json"
          callback-port    = var.tsuru_oidc.callback_port
          groups-in-claims = true
          # Tsuru doesn't check the audience (ADR 0035); iss at least pins the issuer.
          valid-claims = merge({ iss = local.infra.oidc_issuer_url }, var.tsuru_oidc_valid_claims)
        }
      }

      provisioner = "kubernetes"
      routers = {
        ingress-router = {
          type = "api"
          # Basic auth in the URL: Tsuru expands env vars only in plain string values.
          api-url = "http://tsuru:$ROUTER_PASSWORD@kubernetes-router.${kubernetes_namespace_v1.tsuru[0].metadata[0].name}/api/ingress"
        }
      }
      docker = {
        registry             = local.tsuru_registry_host
        repository-namespace = var.tsuru_registry.project
        router               = "ingress-router"
      }
      # Defaults for the "local" cluster Tsuru registers on first start. The
      # pull secret (docker-config-json) is JSON, which the config parser turns
      # into a map, so it is set on the cluster at bootstrap (docs/operations.md).
      clusters = {
        defaults = {
          build-service-address         = "dns:///deploy-agent.${kubernetes_namespace_v1.tsuru_build[0].metadata[0].name}:80"
          build-service-tls             = "false"
          registry                      = local.tsuru_registry_host
          registry-insecure             = "false"
          disable-default-node-selector = "true"
        }
      }
    }
  })]

  depends_on = [helm_release.mongodb, helm_release.tsuru_router, helm_release.tsuru_deploy_agent]
}
