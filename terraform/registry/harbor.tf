# Harbor's configuration (docs/adr/0033): login through Pocket ID, the tsuru
# project with its retention policy, and the robot Tsuru pushes and pulls with.

# Pocket ID is the only login; the local admin stays as break-glass. Users are
# created on first login, named after their Pocket ID username.
resource "harbor_config_auth" "oidc" {
  auth_mode         = "oidc_auth"
  primary_auth_mode = true
  oidc_name         = "Pocket ID"
  oidc_endpoint     = local.infra.oidc_issuer_url
  oidc_client_id    = local.identity.harbor_oidc.client_id
  # Write-only: sent to Harbor, never stored in this state. Bump the version
  # after a new identity client (new secret) to push it again.
  oidc_client_secret_wo         = local.identity.harbor_oidc.client_secret
  oidc_client_secret_wo_version = 1
  oidc_scope                    = "openid,email,profile,groups"
  oidc_verify_cert              = true
  oidc_auto_onboard             = true
  oidc_user_claim               = "preferred_username"
  oidc_groups_claim             = "groups"
  oidc_admin_group              = "k8s-admins"
}

resource "harbor_project" "tsuru" {
  name                   = "tsuru"
  public                 = false
  vulnerability_scanning = true
  # Tsuru tags every deploy; old ones go through the retention policy.
  force_destroy = false
}

resource "harbor_retention_policy" "tsuru" {
  scope    = harbor_project.tsuru.id
  schedule = "Daily"

  # The last 10 pushes of each app image are enough to roll back.
  rule {
    most_recently_pushed = 10
    repo_matching        = "**"
    tag_matching         = "**"
  }
}

# Frees the blobs that retention and deletes leave behind.
resource "harbor_garbage_collection" "weekly" {
  schedule        = "0 0 5 * * 0" # Sundays 05:00 UTC (seconds first)
  delete_untagged = true
}

resource "random_password" "tsuru_robot" {
  length  = 32
  special = false
}

# Tsuru's deploy-agent pushes and every app pod pulls with this account.
resource "harbor_robot_account" "tsuru" {
  name        = "tsuru"
  description = "Tsuru builds (push) and app pods (pull), docs/adr/0034"
  level       = "project"
  # Write-only, like the OIDC secret; bump the version to rotate.
  secret_wo         = random_password.tsuru_robot.result
  secret_wo_version = 1

  permissions {
    kind      = "project"
    namespace = harbor_project.tsuru.name

    access {
      action   = "push"
      resource = "repository"
    }
    access {
      action   = "pull"
      resource = "repository"
    }
  }
}
