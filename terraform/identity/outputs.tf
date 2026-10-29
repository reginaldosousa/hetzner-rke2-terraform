output "kubectl_client_id" {
  description = "Set as oidc_client_id in terraform/infra (the apiserver's audience)."
  value       = pocketid_client.kubectl.id
}

output "headscale_oidc_client_id" {
  description = "Set as headscale_oidc_client_id in terraform/infra."
  value       = one(pocketid_client.headscale[*].id)
}

output "headscale_oidc_client_secret" {
  description = "Set as headscale_oidc_client_secret in terraform/infra. Pocket ID only returns it when the client is created."
  value       = one(pocketid_client.headscale[*].client_secret)
  sensitive   = true
}

output "grafana_oidc" {
  description = "Set as grafana_oidc in terraform/cluster (grafana-oidc.auto.tfvars.json, see docs/operations.md). Pocket ID only returns the secret when the client is created."
  value = {
    client_id     = pocketid_client.grafana.id
    client_secret = pocketid_client.grafana.client_secret
  }
  sensitive = true
}
