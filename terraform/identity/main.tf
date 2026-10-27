# Pocket ID's URL comes from the infra root, the same value the apiserver trusts.
data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket    = "rke2-tfstate"
    key       = "infra/terraform.tfstate"
    region    = "auto"
    profile   = "r2"
    endpoints = { s3 = "https://9cf4130ce6c67ffa7f69903b7e2e4b15.r2.cloudflarestorage.com" }

    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs
}
