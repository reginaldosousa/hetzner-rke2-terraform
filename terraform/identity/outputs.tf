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
