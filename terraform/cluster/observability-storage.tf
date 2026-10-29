# Object storage for logs and traces (ADR 0029): one R2 bucket each for Loki
# and Tempo, and an account token per bucket that can only read and write its
# objects. Only the WAL and compactor scratch stay on node volumes.
locals {
  observability_buckets = {
    loki  = var.loki_bucket
    tempo = var.tempo_bucket
  }
  r2_endpoint = "${var.cloudflare_account_id}.r2.cloudflarestorage.com"
}

resource "cloudflare_r2_bucket" "observability" {
  for_each = local.observability_buckets

  account_id = var.cloudflare_account_id
  name       = each.value
  location   = "weur"

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_account_token" "observability" {
  for_each = local.observability_buckets

  account_id = var.cloudflare_account_id
  name       = "${local.infra.cluster_name}-${each.key}"

  policies = [{
    effect = "allow"
    permission_groups = [{
      id = one(data.cloudflare_account_api_token_permission_groups_list.r2_object_write.result).id
    }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${cloudflare_r2_bucket.observability[each.key].name}" = "*"
    })
  }]
}

# Read as environment variables and expanded into the config at startup
# (-config.expand-env), so the keys never appear in the Helm values.
resource "kubernetes_secret_v1" "observability_r2" {
  for_each = local.observability_buckets

  metadata {
    name      = "${each.key}-r2"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  data = {
    AWS_ACCESS_KEY_ID     = cloudflare_account_token.observability[each.key].id
    AWS_SECRET_ACCESS_KEY = sha256(cloudflare_account_token.observability[each.key].value)
  }
}
