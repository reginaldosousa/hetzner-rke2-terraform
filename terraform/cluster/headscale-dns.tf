# Headscale's name on the gateway (docs/adr/0025). Not proxied: clients speak
# Tailscale's protocol and DERP to it directly, and ACME validates on :443.
locals {
  # No try(): a missing output must fail the plan, not plan this record away.
  headscale_hostname = trimprefix(local.infra.headscale_url, "https://")
}

resource "cloudflare_dns_record" "headscale" {
  count = local.headscale_hostname == "" ? 0 : 1

  zone_id = one([for domain, zone in data.cloudflare_zone.managed : zone.zone_id if endswith(local.headscale_hostname, ".${domain}")])
  name    = local.headscale_hostname
  type    = "A"
  content = local.infra.gateway_public_ip
  ttl     = 300
  proxied = false
  comment = "Headscale on the gateway, managed by terraform/cluster"
}
