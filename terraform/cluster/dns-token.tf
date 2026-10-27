# Token for external-dns and cert-manager's DNS-01 solver: Zone Read + DNS Write
# on the zones in var.external_dns_domains only. It lives in-cluster, so it is
# kept that narrow; the provisioning token that creates it never leaves Terraform.
data "cloudflare_zone" "managed" {
  for_each = toset(var.external_dns_domains)

  filter = {
    name    = each.value
    account = { id = var.cloudflare_account_id }
  }
}

data "cloudflare_account_api_token_permission_groups_list" "dns" {
  for_each = toset(["Zone Read", "DNS Write"])

  account_id = var.cloudflare_account_id
  name       = each.value
}

resource "cloudflare_account_token" "dns" {
  account_id = var.cloudflare_account_id
  name       = "${local.infra.cluster_name}-dns"

  policies = [{
    effect = "allow"
    permission_groups = [
      for group in data.cloudflare_account_api_token_permission_groups_list.dns : { id = one(group.result).id }
    ]
    resources = jsonencode({
      for zone in data.cloudflare_zone.managed : "com.cloudflare.api.account.zone.${zone.zone_id}" => "*"
    })
  }]
}
