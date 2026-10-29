# Logs (ADR 0029): Loki as one process, chunks and index in R2. The collectors
# push OTLP to /otlp; Loki turns the k8s resource attributes into labels.
resource "helm_release" "loki" {
  name       = "loki"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_chart_version

  values = [yamlencode({
    deploymentMode = "SingleBinary"

    loki = {
      auth_enabled = false
      commonConfig = { replication_factor = 1 }
      schemaConfig = {
        configs = [{
          from         = "2026-10-29"
          store        = "tsdb"
          object_store = "s3"
          schema       = "v13"
          index        = { prefix = "index_", period = "24h" }
        }]
      }
      storage = {
        type        = "s3"
        bucketNames = { chunks = cloudflare_r2_bucket.observability["loki"].name, ruler = cloudflare_r2_bucket.observability["loki"].name }
        s3 = {
          endpoint         = local.r2_endpoint
          region           = "auto"
          s3ForcePathStyle = true
          # From the loki-r2 Secret, expanded at startup.
          accessKeyId     = "$${AWS_ACCESS_KEY_ID}"
          secretAccessKey = "$${AWS_SECRET_ACCESS_KEY}"
        }
      }
      compactor = {
        retention_enabled    = true
        delete_request_store = "s3"
      }
      limits_config = {
        retention_period = var.loki_retention
      }
    }

    singleBinary = {
      replicas     = 1
      extraArgs    = ["-config.expand-env=true"]
      extraEnvFrom = [{ secretRef = { name = kubernetes_secret_v1.observability_r2["loki"].metadata[0].name } }]
      # WAL and compactor scratch; 10 GB is the smallest Hetzner volume.
      persistence = { size = "10Gi" }
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "1Gi" }
      }
    }
    # The scalable targets default to 3 replicas each.
    read    = { replicas = 0 }
    write   = { replicas = 0 }
    backend = { replicas = 0 }

    # Memcached caches and the nginx gateway cost more memory than they save
    # at this size; the collectors talk to the loki Service directly.
    gateway      = { enabled = false }
    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }
    lokiCanary   = { enabled = false }
    test         = { enabled = false }

    monitoring = {
      dashboards     = { enabled = true }
      serviceMonitor = { enabled = true, metricsInstance = { enabled = false } }
      rules = {
        enabled = true
        configs = { LokiCanaryLatency = { enabled = false } }
      }
    }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}
