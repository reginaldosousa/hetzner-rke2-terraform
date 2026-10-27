# Off-site copy of Headscale's database (docs/adr/0026): Litestream on the
# gateway replicates it here, and a rebuilt gateway restores from it. The token
# can only read and write objects in this bucket. It goes to terraform/infra
# through the headscale_backup output, because infra never talks to Cloudflare.
resource "cloudflare_r2_bucket" "headscale" {
  count = local.headscale_hostname == "" ? 0 : 1

  account_id = var.cloudflare_account_id
  name       = var.headscale_backup_bucket
  location   = "weur" # placement hint; the gateway is in Germany

  lifecycle {
    # Holds the only copy of the tailnet's nodes and users. Delete it by hand.
    prevent_destroy = true
  }
}

resource "cloudflare_account_token" "headscale_backup" {
  count = local.headscale_hostname == "" ? 0 : 1

  account_id = var.cloudflare_account_id
  name       = "${local.infra.cluster_name}-headscale-backup"

  policies = [{
    effect = "allow"
    permission_groups = [{
      id = one(data.cloudflare_account_api_token_permission_groups_list.r2_object_write.result).id
    }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${cloudflare_r2_bucket.headscale[0].name}" = "*"
    })
  }]
}
