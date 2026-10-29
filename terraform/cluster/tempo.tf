# Traces (ADR 0029): Tempo as one process, blocks in R2. Its metrics-generator
# turns spans into RED metrics and a service graph, remote-written to
# Prometheus (enableRemoteWriteReceiver in monitoring.tf).
resource "helm_release" "tempo" {
  name       = "tempo"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "tempo"
  version    = var.tempo_chart_version

  values = [yamlencode({
    tempo = {
      reportingEnabled = false
      retention        = var.tempo_retention
      extraArgs        = { "config.expand-env" = "true" }
      extraEnvFrom     = [{ secretRef = { name = kubernetes_secret_v1.observability_r2["tempo"].metadata[0].name } }]

      storage = {
        trace = {
          backend = "s3"
          s3 = {
            bucket         = cloudflare_r2_bucket.observability["tempo"].name
            endpoint       = local.r2_endpoint
            region         = "auto"
            forcepathstyle = true
            # From the tempo-r2 Secret, expanded at startup.
            access_key = "$${AWS_ACCESS_KEY_ID}"
            secret_key = "$${AWS_SECRET_ACCESS_KEY}"
          }
          wal = { path = "/var/tempo/wal" }
        }
      }

      metricsGenerator = {
        enabled        = true
        remoteWriteUrl = "http://kube-prometheus-stack-prometheus.${kubernetes_namespace_v1.monitoring.metadata[0].name}:9090/api/v1/write"
        storage        = { path = "/var/tempo/generator/wal" }
      }
      overrides = {
        defaults = {
          metrics_generator = { processors = ["service-graphs", "span-metrics"] }
        }
      }

      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "1Gi" }
      }
    }

    # WAL and generator state; 10 GB is the smallest Hetzner volume.
    persistence    = { enabled = true, size = "10Gi" }
    serviceMonitor = { enabled = true }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}
