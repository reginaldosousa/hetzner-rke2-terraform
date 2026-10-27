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

  values = [yamlencode({
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

    # Reached with kubectl port-forward over the VPN; no Ingress.
    grafana = {
      admin = {
        existingSecret = kubernetes_secret_v1.grafana_admin.metadata[0].name
        userKey        = "admin-user"
        passwordKey    = "admin-password"
      }
    }
  })]
}
