# Who may do what through Pocket ID (docs/adr/0023, 0024). The apiserver maps
# a group to "oidc:<name>"; terraform/cluster/oidc-rbac.tf binds k8s-admins.
resource "pocketid_group" "k8s_admins" {
  name          = "k8s-admins"
  friendly_name = "Kubernetes admins"
}

# Members may log in to the tailnet (Headscale's allowed_groups, docs/adr/0025).
resource "pocketid_group" "vpn" {
  name          = "vpn"
  friendly_name = "VPN"
}

locals {
  groups = {
    (pocketid_group.k8s_admins.name) = pocketid_group.k8s_admins.id
    (pocketid_group.vpn.name)        = pocketid_group.vpn.id
  }
  # "" until infra sets headscale_hostname. No try(): a missing output must
  # fail the plan, not plan the client (and its secret) away.
  headscale_url = local.infra.headscale_url
}

# kubelogin: public client with PKCE on localhost callbacks. Its ID is the
# audience in the masters' AuthenticationConfiguration (infra oidc_client_id),
# so it must never be recreated with a new one.
resource "pocketid_client" "kubectl" {
  name                = "kubectl"
  is_public           = true
  pkce_enabled        = true
  callback_urls       = ["http://localhost:8000", "http://localhost:18000"]
  allowed_user_groups = [pocketid_group.k8s_admins.id]

  lifecycle {
    prevent_destroy = true
  }
}

# Headscale on the gateway: a confidential client (it keeps a secret, unlike
# kubelogin), PKCE on top. Its ID and secret go to infra's headscale_oidc_*.
resource "pocketid_client" "headscale" {
  count = local.headscale_url == "" ? 0 : 1

  name                = "headscale"
  is_public           = false
  pkce_enabled        = true
  callback_urls       = ["${local.headscale_url}/oidc/callback"]
  allowed_user_groups = [pocketid_group.vpn.id]

  lifecycle {
    # A new client means a new secret: VPN logins fail until infra is reapplied.
    prevent_destroy = true
  }
}

resource "pocketid_user" "this" {
  for_each = var.users

  username   = each.key
  email      = each.value.email
  first_name = each.value.first_name
  last_name  = each.value.last_name
  is_admin   = each.value.is_admin
  # Asserted by whoever adds the user here; Headscale only accepts verified emails.
  email_verified = true
  disabled       = each.value.disabled
  groups         = [for g in each.value.groups : local.groups[g]]

  lifecycle {
    # Deleting a user also deletes their passkeys.
    prevent_destroy = true
  }
}
