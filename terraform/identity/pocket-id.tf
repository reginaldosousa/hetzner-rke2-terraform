# Who may do what through Pocket ID (docs/adr/0023, 0024). The apiserver maps
# a group to "oidc:<name>"; terraform/cluster/oidc-rbac.tf binds k8s-admins.
resource "pocketid_group" "k8s_admins" {
  name          = "k8s-admins"
  friendly_name = "Kubernetes admins"
}

locals {
  groups = {
    (pocketid_group.k8s_admins.name) = pocketid_group.k8s_admins.id
  }
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

resource "pocketid_user" "this" {
  for_each = var.users

  username   = each.key
  email      = each.value.email
  first_name = each.value.first_name
  last_name  = each.value.last_name
  is_admin   = each.value.is_admin
  disabled   = each.value.disabled
  groups     = [for g in each.value.groups : local.groups[g]]

  lifecycle {
    # Deleting a user also deletes their passkeys.
    prevent_destroy = true
  }
}
