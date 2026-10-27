# Off-site etcd snapshots (ADR 0019): an R2 bucket and an account token that
# can only read and write objects in it. The masters read the credentials from
# a Secret (etcd-s3-config-secret in their RKE2 config), not user_data: pods
# could read user_data from the metadata service.
resource "cloudflare_r2_bucket" "etcd_snapshots" {
  account_id = var.cloudflare_account_id
  name       = var.etcd_s3_bucket
  location   = "weur" # placement hint; the masters are in Germany

  lifecycle {
    # Holds the only off-site copy of the cluster. Delete it by hand.
    prevent_destroy = true
  }
}

data "cloudflare_account_api_token_permission_groups_list" "r2_object_write" {
  account_id = var.cloudflare_account_id
  name       = "Workers R2 Storage Bucket Item Write"
}

resource "cloudflare_account_token" "etcd_snapshots" {
  account_id = var.cloudflare_account_id
  name       = "${local.infra.cluster_name}-etcd-snapshots"

  policies = [{
    effect = "allow"
    permission_groups = [{
      id = one(data.cloudflare_account_api_token_permission_groups_list.r2_object_write.result).id
    }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${cloudflare_r2_bucket.etcd_snapshots.name}" = "*"
    })
  }]
}

resource "kubernetes_secret_v1" "etcd_s3" {
  metadata {
    name      = local.infra.etcd_s3_config_secret
    namespace = "kube-system"
  }

  type = "etcd.k3s.cattle.io/s3-config-secret"

  data = {
    "etcd-s3-endpoint"           = "${var.cloudflare_account_id}.r2.cloudflarestorage.com"
    "etcd-s3-bucket"             = cloudflare_r2_bucket.etcd_snapshots.name
    "etcd-s3-folder"             = local.infra.cluster_name
    "etcd-s3-region"             = "auto"
    "etcd-s3-bucket-lookup-type" = "path"
    # R2's S3 credentials for an API token: id and sha256 of the value.
    "etcd-s3-access-key" = cloudflare_account_token.etcd_snapshots.id
    "etcd-s3-secret-key" = sha256(cloudflare_account_token.etcd_snapshots.value)
    # Per master; snapshots run every 6h, so 28 = 7 days.
    "etcd-s3-retention" = "28"
  }
}
