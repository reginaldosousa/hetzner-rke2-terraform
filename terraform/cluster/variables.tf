variable "kubeconfig_path" {
  description = "Kubeconfig produced by scripts/get-kubeconfig.sh."
  type        = string
  default     = "../../kubeconfig"
}

variable "karpenter_chart_version" {
  description = "karpenter-provider-hetzner chart version (ships the karpenter.sh CRDs too)."
  type        = string
  default     = "3.0.1"
}

variable "nodepool_cpu_limit" {
  description = "Max total vCPUs Karpenter may provision across workers."
  type        = string
  default     = "32"
}

variable "worker_locations" {
  description = "Locations Karpenter may place workers in. All must be in the infra network's zone (eu-central)."
  type        = list(string)
  default     = ["nbg1", "fsn1"]
}

variable "external_dns_chart_version" {
  description = "kubernetes-sigs external-dns chart version."
  type        = string
  default     = "1.23.0"
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token for external-dns (Zone:Read + DNS:Edit on the managed zones)."
  type        = string
  sensitive   = true
}

variable "external_dns_domains" {
  description = "Cloudflare zones external-dns may manage, e.g. [\"example.com\"]."
  type        = list(string)

  validation {
    condition     = length(var.external_dns_domains) > 0
    error_message = "List at least one zone; an empty filter would let external-dns touch every zone the token can reach."
  }
}

variable "cert_manager_chart_version" {
  description = "jetstack cert-manager chart version."
  type        = string
  default     = "v1.21.3"
}

variable "acme_email" {
  description = "Contact email for the Let's Encrypt ACME account (expiry and policy notices)."
  type        = string
}

variable "etcd_s3_endpoint" {
  description = "S3 endpoint (host only, no scheme) for etcd snapshots. Defaults to the Cloudflare R2 account that holds the Terraform state."
  type        = string
  default     = "9cf4130ce6c67ffa7f69903b7e2e4b15.r2.cloudflarestorage.com"

  validation {
    condition     = !can(regex("://", var.etcd_s3_endpoint))
    error_message = "etcd_s3_endpoint is a host name without scheme; RKE2 uses HTTPS."
  }
}

variable "etcd_s3_bucket" {
  description = "Bucket for etcd snapshots. Keep it separate from the Terraform state bucket."
  type        = string
  default     = "rke2-etcd-snapshots"
}

variable "etcd_s3_access_key" {
  description = "Access key of an R2 token limited to Object Read & Write on etcd_s3_bucket."
  type        = string
  sensitive   = true
}

variable "etcd_s3_secret_key" {
  description = "Secret key matching etcd_s3_access_key."
  type        = string
  sensitive   = true
}
