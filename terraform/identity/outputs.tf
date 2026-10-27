output "kubectl_client_id" {
  description = "Set as oidc_client_id in terraform/infra (the apiserver's audience)."
  value       = pocketid_client.kubectl.id
}
