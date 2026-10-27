terraform {
  required_version = ">= 1.10, < 2.0" # 1.10: S3 use_lockfile

  required_providers {
    # Community provider (docs/adr/0024). Pinned exactly: it holds an admin
    # API key, so every upgrade gets a read of the diff first.
    pocketid = {
      source  = "Trozz/pocketid"
      version = "2.4.2"
    }
  }
}

# Pocket ID's admin API over its public URL (terraform/cluster/pocket-id.tf).
provider "pocketid" {
  base_url  = local.infra.oidc_issuer_url
  api_token = var.pocket_id_api_token
}
