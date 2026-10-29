# Metrics and alerting: kube-prometheus-stack, with Alertmanager sending to
# Telegram. node-exporter needs hostNetwork/hostPID/hostPath, so this namespace
# is an explicit exception to the cluster-wide Pod Security baseline (ADR 0018).
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# Mounted into Alertmanager as files, so the bot token and the dead man's
# switch URL never appear in the rendered Helm values.
resource "kubernetes_secret_v1" "alertmanager_receivers" {
  metadata {
    name      = "alertmanager-receivers"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  data = {
    telegram-bot-token = var.telegram_bot_token
    deadmans-switch    = var.deadmans_switch_url
  }
}

resource "random_password" "grafana_admin" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin.result
  }
}

locals {
  alertmanager_secrets_dir = "/etc/alertmanager/secrets/${kubernetes_secret_v1.alertmanager_receivers.metadata[0].name}"

  # Alerts leave the cluster through the NAT gateway, so a dead gateway (or a
  # dead Alertmanager) is silent. The always-firing Watchdog alert goes to an
  # external dead man's switch (e.g. healthchecks.io) that alerts when it stops.
  deadmans_switch = var.deadmans_switch_url != ""

  alertmanager_config = {
    route = {
      receiver        = "telegram"
      group_by        = ["alertname", "namespace"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "4h"
      routes = [
        {
          matchers        = ["alertname = Watchdog"]
          receiver        = local.deadmans_switch ? "deadmans-switch" : "null"
          repeat_interval = "1m"
        },
        { matchers = ["alertname = InfoInhibitor"], receiver = "null" },
      ]
    }
    inhibit_rules = [
      {
        source_matchers = ["severity = critical"]
        target_matchers = ["severity =~ warning|info"]
        equal           = ["namespace", "alertname"]
      },
      {
        source_matchers = ["severity = warning"]
        target_matchers = ["severity = info"]
        equal           = ["namespace", "alertname"]
      },
      {
        source_matchers = ["alertname = InfoInhibitor"]
        target_matchers = ["severity = info"]
        equal           = ["namespace"]
      },
    ]
    receivers = concat(
      [
        { name = "null" },
        {
          name = "telegram"
          telegram_configs = [{
            bot_token_file = "${local.alertmanager_secrets_dir}/telegram-bot-token"
            chat_id        = tonumber(var.telegram_chat_id)
            send_resolved  = true
          }]
        },
      ],
      local.deadmans_switch ? [{
        name = "deadmans-switch"
        webhook_configs = [{
          url_file      = "${local.alertmanager_secrets_dir}/deadmans-switch"
          send_resolved = false
        }]
      }] : [],
    )
  }

  # Control-plane components run as static pods on the masters, outside any
  # Service; scrape them by IP (enabled by the masters' 30-metrics.yaml drop-in).
  control_plane_endpoints = { endpoints = local.infra.master_ips }
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_chart_version

  values = concat([yamlencode({
    kubeEtcd              = merge(local.control_plane_endpoints, { service = { port = 2381, targetPort = 2381 } })
    kubeControllerManager = local.control_plane_endpoints
    kubeScheduler         = local.control_plane_endpoints
    # RKE2's kube-proxy only serves metrics on localhost.
    kubeProxy = { enabled = false }

    "prometheus-node-exporter" = {
      # Every node, masters included (they carry CriticalAddonsOnly:NoExecute).
      tolerations = [{ operator = "Exists" }]
    }

    alertmanager = {
      config = local.alertmanager_config
      alertmanagerSpec = {
        secrets = [kubernetes_secret_v1.alertmanager_receivers.metadata[0].name]
        storage = {
          volumeClaimTemplate = {
            # 10 GB is the smallest Hetzner volume.
            spec = { resources = { requests = { storage = "10Gi" } } }
          }
        }
        resources = {
          requests = { cpu = "10m", memory = "64Mi" }
          limits   = { memory = "128Mi" }
        }
      }
    }

    prometheus = {
      prometheusSpec = {
        retention     = "15d"
        retentionSize = "18GB"
        storageSpec = {
          volumeClaimTemplate = {
            spec = { resources = { requests = { storage = "20Gi" } } }
          }
        }
        resources = {
          requests = { cpu = "200m", memory = "1Gi" }
          limits   = { memory = "2Gi" }
        }
        # Pick up ServiceMonitors/PodMonitors/rules from every release, not
        # only this one.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
      }
    }

    # Internal app (docs/adr/0027): reachable only over the VPN, at
    # https://grafana.<internal domain>.
    grafana = {
      admin = {
        existingSecret = kubernetes_secret_v1.grafana_admin.metadata[0].name
        userKey        = "admin-user"
        passwordKey    = "admin-password"
      }
      "grafana.ini" = {
        server = { root_url = "https://grafana.${local.internal_domain}" }
      }
      ingress = {
        enabled          = true
        ingressClassName = "traefik"
        # TLS from the zone's wildcard in Traefik's default store
        # (internal-apps.tf), so no tls block or issuer here.
        annotations = {
          "traefik.ingress.kubernetes.io/router.entrypoints" = "internal"
          "traefik.ingress.kubernetes.io/router.tls"         = "true"
        }
        hosts = ["grafana.${local.internal_domain}"]
      }
    }
  })], local.grafana_oidc_values)
}

# Grafana login through Pocket ID (client in terraform/identity), once
# grafana_oidc is set; until then only the admin password works. k8s-admins
# are Admins, vpn members Viewers, anyone else is refused. The admin user
# stays as break-glass at /login?disableAutoLogin=true.
resource "kubernetes_secret_v1" "grafana_oidc" {
  count = local.grafana_oidc ? 1 : 0

  metadata {
    name      = "grafana-oidc"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  data = {
    client-secret = var.grafana_oidc.client_secret
  }
}

locals {
  # Whether it is set is not itself secret; count can't use sensitive values.
  grafana_oidc = nonsensitive(var.grafana_oidc != null)
  # A separate values document, so the main one stays a single object type.
  grafana_oidc_values = !local.grafana_oidc ? [] : [yamlencode({
    grafana = {
      # Read from the Secret at runtime: never in the Helm values or the ConfigMap.
      envValueFrom = {
        GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = {
          secretKeyRef = { name = kubernetes_secret_v1.grafana_oidc[0].metadata[0].name, key = "client-secret" }
        }
      }
      "grafana.ini" = {
        auth = {
          signout_redirect_url = "${local.infra.oidc_issuer_url}/api/oidc/end-session"
        }
        "auth.generic_oauth" = {
          enabled   = true
          name      = "Pocket ID"
          client_id = var.grafana_oidc.client_id
          scopes    = "openid profile email groups"
          auth_url  = "${local.infra.oidc_issuer_url}/authorize"
          token_url = "${local.infra.oidc_issuer_url}/api/oidc/token"
          api_url   = "${local.infra.oidc_issuer_url}/api/oidc/userinfo"
          use_pkce  = true
          # Straight to Pocket ID; break-glass at /login?disableAutoLogin=true.
          auto_login    = true
          allow_sign_up = true
          # Pocket ID's client already admits only these groups; this is the
          # second check, and the role is re-synced at every login.
          groups_attribute_path = "groups"
          allowed_groups        = "k8s-admins vpn"
          role_attribute_path   = "contains(groups[*], 'k8s-admins') && 'Admin' || contains(groups[*], 'vpn') && 'Viewer'"
          role_attribute_strict = true
          skip_org_role_sync    = false
          login_attribute_path  = "preferred_username"
          name_attribute_path   = "name"
          email_attribute_path  = "email"
        }
      }
    }
  })]
}
