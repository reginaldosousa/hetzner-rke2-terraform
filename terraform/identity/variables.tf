variable "pocket_id_api_token" {
  description = "Pocket ID API key (Settings > Admin > API Keys). Full admin over identities: keep it out of the cluster and give it an expiry."
  type        = string
  sensitive   = true
}

variable "users" {
  description = "Pocket ID users by username. groups are names from pocket-id.tf (local.groups). Users sign in with passkeys they add themselves (one-time link from the admin UI). Revoke with disabled = true here: a UI-only change is reverted on the next apply."
  type = map(object({
    email      = string
    first_name = string
    last_name  = optional(string)
    is_admin   = optional(bool, false)
    disabled   = optional(bool, false)
    groups     = optional(list(string), [])
  }))
  default = {}
}

variable "harbor_hostname" {
  description = "Harbor's hostname, terraform/cluster's harbor_hostname (docs/adr/0033); used for its OIDC callback."
  type        = string
  default     = "harbor.devcomm.com.br"
}
