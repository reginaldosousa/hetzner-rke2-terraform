# State lives in Cloudflare R2 (S3-compatible). Credentials come from the
# "r2" AWS profile (aws configure --profile r2), never from this file.
# R2 has no object versioning: back up state with scripts/backup-state.sh.
terraform {
  backend "s3" {
    bucket       = "rke2-tfstate"
    key          = "cluster/terraform.tfstate"
    region       = "auto"
    profile      = "r2"
    endpoints    = { s3 = "https://9cf4130ce6c67ffa7f69903b7e2e4b15.r2.cloudflarestorage.com" }
    use_lockfile = true # atomic If-None-Match on R2; needs Terraform >= 1.10

    # R2 is not AWS: skip the AWS-only checks.
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}
