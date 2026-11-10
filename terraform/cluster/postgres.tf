# PostgreSQL (ADR 0031): CloudNativePG runs every Postgres in the cluster, and
# the Barman Cloud plugin archives WAL and daily base backups to R2. Each
# database is a release of charts/pg-cluster in its consumer's namespace, so
# the <name>-app credentials Secret sits next to the app.
resource "kubernetes_namespace_v1" "cnpg" {
  metadata {
    name = "cnpg-system"
  }
}

resource "helm_release" "cnpg" {
  name       = "cnpg"
  namespace  = kubernetes_namespace_v1.cnpg.metadata[0].name
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cloudnative-pg"
  version    = var.cnpg_chart_version

  values = [yamlencode({
    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "512Mi" }
    }
    monitoring = {
      # The operator's own metrics; each database adds a PodMonitor of its own.
      podMonitorEnabled = true
      grafanaDashboard = {
        create    = true
        namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
      }
    }
  })]

  # PodMonitor CRD.
  depends_on = [helm_release.kube_prometheus_stack]
}

# Has to live in the operator's namespace; its certificates come from
# cert-manager (a self-signed issuer the chart creates).
resource "helm_release" "cnpg_barman_plugin" {
  name       = "barman-cloud"
  namespace  = kubernetes_namespace_v1.cnpg.metadata[0].name
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "plugin-barman-cloud"
  version    = var.cnpg_barman_plugin_chart_version

  values = [yamlencode({
    resources = {
      requests = { cpu = "10m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    }
  })]

  depends_on = [helm_release.cnpg, helm_release.cert_manager]
}

resource "cloudflare_r2_bucket" "postgres" {
  account_id = var.cloudflare_account_id
  name       = var.postgres_bucket
  location   = "weur"

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_account_token" "postgres_backup" {
  account_id = var.cloudflare_account_id
  name       = "${local.infra.cluster_name}-postgres"

  policies = [{
    effect = "allow"
    permission_groups = [{
      id = one(data.cloudflare_account_api_token_permission_groups_list.r2_object_write.result).id
    }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${cloudflare_r2_bucket.postgres.name}" = "*"
    })
  }]
}
