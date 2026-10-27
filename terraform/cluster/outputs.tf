output "headscale_backup" {
  description = "Litestream's R2 target for Headscale; set as headscale_backup in terraform/infra (docs/operations.md). Null until Headscale is configured."
  sensitive   = true
  value = local.headscale_hostname == "" ? null : {
    endpoint = "https://${var.cloudflare_account_id}.r2.cloudflarestorage.com"
    bucket   = cloudflare_r2_bucket.headscale[0].name
    # R2's S3 credentials for an API token: id and sha256 of the value.
    access_key_id     = cloudflare_account_token.headscale_backup[0].id
    secret_access_key = sha256(cloudflare_account_token.headscale_backup[0].value)
  }
}
