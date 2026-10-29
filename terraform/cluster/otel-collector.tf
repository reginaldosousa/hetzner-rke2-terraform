# Telemetry pipeline (ADR 0029). otel-agent runs on every node: it tails pod
# logs and receives apps' OTLP, adds the pod's k8s attributes, and forwards
# logs to Loki, traces to Tempo and metrics to Prometheus. otel-cluster is a
# single replica that turns Kubernetes Events into logs, so they outlive the
# API server's 1h TTL. Cluster and node metrics stay with kube-prometheus-stack.
locals {
  monitoring_ns = kubernetes_namespace_v1.monitoring.metadata[0].name

  otel_exporters = {
    "otlphttp/loki"       = { endpoint = "http://loki.${local.monitoring_ns}:3100/otlp" }
    "otlp/tempo"          = { endpoint = "tempo.${local.monitoring_ns}:4317", tls = { insecure = true } }
    "otlphttp/prometheus" = { endpoint = "http://kube-prometheus-stack-prometheus.${local.monitoring_ns}:9090/api/v1/otlp" }
    debug                 = null
  }

  # Only OTLP in; the self-metrics are scraped through the ServiceMonitor.
  otel_disabled_ports = {
    "jaeger-compact" = { enabled = false }
    "jaeger-thrift"  = { enabled = false }
    "jaeger-grpc"    = { enabled = false }
    zipkin           = { enabled = false }
    metrics          = { enabled = true }
  }
  otel_disabled_receivers = { jaeger = null, zipkin = null, prometheus = null }
  otel_agent_processors   = ["memory_limiter", "k8s_attributes", "batch"]

  otel_common_values = {
    image          = { repository = "otel/opentelemetry-collector-contrib", tag = var.otel_collector_version }
    serviceMonitor = { enabled = true }
    prometheusRule = { enabled = true, defaultRules = { enabled = true } }
  }
}

resource "helm_release" "otel_agent" {
  name       = "otel-agent"
  namespace  = local.monitoring_ns
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = var.otel_collector_chart_version

  values = [yamlencode(merge(local.otel_common_values, {
    fullnameOverride = "otel-agent"
    mode             = "daemonset"

    presets = {
      # Checkpoints on the host, so a restart resumes where it stopped instead
      # of skipping or re-sending lines.
      logsCollection       = { enabled = true, storeCheckpoints = true }
      kubernetesAttributes = { enabled = true }
    }

    # internalTrafficPolicy Local (the chart's default for a DaemonSet): apps
    # reach the agent on their own node. No hostPorts: nothing outside the
    # cluster sends here.
    service = { enabled = true }
    ports = merge(local.otel_disabled_ports, {
      otlp        = { hostPort = 0 }
      "otlp-http" = { hostPort = 0 }
    })

    # Every node, masters included (they carry CriticalAddonsOnly:NoExecute).
    tolerations = [{ operator = "Exists" }]

    config = {
      receivers = local.otel_disabled_receivers
      exporters = local.otel_exporters
      service = {
        pipelines = {
          # The presets add filelog to logs; k8s_attributes is listed so it
          # runs after memory_limiter instead of being prepended.
          logs    = { receivers = ["otlp"], processors = local.otel_agent_processors, exporters = ["otlphttp/loki"] }
          traces  = { receivers = ["otlp"], processors = local.otel_agent_processors, exporters = ["otlp/tempo"] }
          metrics = { receivers = ["otlp"], processors = local.otel_agent_processors, exporters = ["otlphttp/prometheus"] }
        }
      }
    }

    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }
  }))]

  depends_on = [helm_release.loki, helm_release.tempo]
}

resource "helm_release" "otel_cluster" {
  name       = "otel-cluster"
  namespace  = local.monitoring_ns
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = var.otel_collector_chart_version

  values = [yamlencode(merge(local.otel_common_values, {
    fullnameOverride = "otel-cluster"
    mode             = "deployment"
    # More than one would ship every Event twice.
    replicaCount = 1

    presets = {
      kubernetesEvents = { enabled = true }
    }

    ports = merge(local.otel_disabled_ports, {
      otlp        = { enabled = false }
      "otlp-http" = { enabled = false }
    })

    config = {
      receivers = merge(local.otel_disabled_receivers, { otlp = null })
      exporters = local.otel_exporters
      service = {
        pipelines = {
          logs    = { receivers = [], processors = ["memory_limiter", "batch"], exporters = ["otlphttp/loki"] }
          traces  = null
          metrics = null
        }
      }
    }

    resources = {
      requests = { cpu = "10m", memory = "64Mi" }
      limits   = { memory = "128Mi" }
    }
  }))]

  depends_on = [helm_release.loki]
}
