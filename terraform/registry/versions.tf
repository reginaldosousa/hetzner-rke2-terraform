terraform {
  required_version = ">= 1.10, < 2.0" # 1.10: S3 use_lockfile

  required_providers {
    # Pinned exactly: it holds Harbor's admin password, so every upgrade gets
    # a read of the diff first.
    harbor = {
      source  = "goharbor/harbor"
      version = "3.12.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

# Harbor's API at its private-LB address (docs/adr/0033): applies need the VPN,
# like terraform/cluster. The admin account keeps basic auth in OIDC mode.
provider "harbor" {
  url      = local.cluster.harbor_url
  username = "admin"
  password = local.cluster.harbor_admin_password
  insecure = false
}
