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

variable "cloudflare_account_id" {
  description = "Cloudflare account that holds the R2 buckets (the Terraform state's and the etcd snapshots')."
  type        = string
  default     = "9cf4130ce6c67ffa7f69903b7e2e4b15"
}

variable "cloudflare_provisioning_api_token" {
  description = "Cloudflare token used only by Terraform: Account > Workers R2 Storage: Edit and Account > Account API Tokens: Edit, Zone > Zone: Read on external_dns_domains. Never stored in the cluster."
  type        = string
  sensitive   = true
}

variable "etcd_s3_bucket" {
  description = "Bucket for etcd snapshots. Keep it separate from the Terraform state bucket."
  type        = string
  default     = "rke2-etcd-snapshots"
}

variable "kured_chart_version" {
  description = "kubereboot kured chart version."
  type        = string
  default     = "6.1.0"
}

variable "min_workers" {
  description = "Workers kept alive even when idle (one Traefik replica each behind the ingress LB). At most one per location in worker_locations."
  type        = number
  default     = 2

  validation {
    condition     = var.min_workers >= 0
    error_message = "min_workers can't be negative."
  }
}

variable "kube_prometheus_stack_chart_version" {
  description = "prometheus-community kube-prometheus-stack chart version."
  type        = string
  default     = "92.14.0"
}

variable "telegram_bot_token" {
  description = "Telegram bot token (from @BotFather) that Alertmanager sends alerts with."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9]+:[A-Za-z0-9_-]{30,}$", var.telegram_bot_token))
    error_message = "telegram_bot_token is the whole token from @BotFather, <bot id>:<secret>, including the part before the colon."
  }
}

variable "telegram_chat_id" {
  description = "Telegram chat that receives alerts (negative for groups)."
  type        = string

  validation {
    condition     = can(regex("^-?[0-9]+$", var.telegram_chat_id))
    error_message = "telegram_chat_id is the numeric chat ID, e.g. -1001234567890."
  }
}

variable "deadmans_switch_url" {
  description = "Optional ping URL of an external dead man's switch (e.g. healthchecks.io) for the always-firing Watchdog alert. Without it, a dead gateway or Alertmanager goes unnoticed."
  type        = string
  default     = ""
  sensitive   = true
}
