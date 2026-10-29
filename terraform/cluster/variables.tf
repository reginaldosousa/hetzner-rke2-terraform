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
  description = "Cloudflare token used only by Terraform: Account > Workers R2 Storage: Edit and Account > Account API Tokens: Edit, Zone > Zone: Read and Zone > DNS: Edit on external_dns_domains (DNS: Edit for records outside the cluster, like Headscale's). Never stored in the cluster."
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
  description = "Workers kept alive even when idle (one Traefik replica each behind the ingress LB). One per location, so at most length(worker_locations)."
  type        = number
  default     = 2

  validation {
    condition     = var.min_workers >= 0 && var.min_workers <= length(var.worker_locations)
    error_message = "min_workers must be between 0 and the number of worker_locations (one placeholder per location)."
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

variable "velero_chart_version" {
  description = "vmware-tanzu velero chart version."
  type        = string
  default     = "12.2.1"
}

variable "velero_aws_plugin_version" {
  description = "velero-plugin-for-aws image tag; must match the Velero version in the chart (1.14.x for Velero 1.18)."
  type        = string
  default     = "v1.14.4"
}

variable "velero_bucket" {
  description = "R2 bucket for Velero backups."
  type        = string
  default     = "rke2-velero"
}

variable "headscale_backup_bucket" {
  description = "R2 bucket for Litestream's copy of Headscale's database."
  type        = string
  default     = "rke2-headscale"
}

variable "pocket_id_version" {
  description = "Pocket ID release (image ghcr.io/pocket-id/pocket-id:<version>-distroless)."
  type        = string
  default     = "v2.19.1"
}

variable "grafana_oidc" {
  description = "Grafana's Pocket ID client, from terraform/identity output grafana_oidc (grafana-oidc.auto.tfvars.json, docs/operations.md). null keeps password-only login, e.g. before identity exists."
  type = object({
    client_id     = string
    client_secret = string
  })
  default   = null
  sensitive = true
}

variable "pocket_id_allowed_cidrs" {
  description = "Public source ranges allowed to reach Pocket ID; [] makes it public. Keep it to your own IP (e.g. [\"203.0.113.7/32\"]) until the first admin is created at /setup, since until then anyone could create it."
  type        = list(string)

  validation {
    condition     = alltrue([for c in var.pocket_id_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "pocket_id_allowed_cidrs entries must be CIDRs, e.g. 203.0.113.7/32."
  }
}

variable "oidc_admin_group" {
  description = "Pocket ID group whose members get cluster-admin through kubectl OIDC login."
  type        = string
  default     = "k8s-admins"
}

variable "loki_chart_version" {
  description = "grafana-community loki chart version (the OSS chart moved there from grafana/ in March 2026)."
  type        = string
  default     = "20.0.3"
}

variable "tempo_chart_version" {
  description = "grafana-community tempo (single binary) chart version."
  type        = string
  default     = "3.2.1"
}

variable "otel_operator_chart_version" {
  description = "open-telemetry opentelemetry-operator chart version."
  type        = string
  default     = "0.128.0"
}

variable "otel_collector_chart_version" {
  description = "open-telemetry opentelemetry-collector chart version."
  type        = string
  default     = "0.178.0"
}

variable "otel_collector_version" {
  description = "otel/opentelemetry-collector-contrib image tag; keep it at the collector chart's appVersion."
  type        = string
  default     = "0.163.2"
}

variable "loki_bucket" {
  description = "R2 bucket for Loki's chunks and index."
  type        = string
  default     = "rke2-loki"
}

variable "tempo_bucket" {
  description = "R2 bucket for Tempo's trace blocks."
  type        = string
  default     = "rke2-tempo"
}

variable "loki_retention" {
  description = "How long Loki keeps logs (a duration, e.g. 720h)."
  type        = string
  default     = "720h"
}

variable "tempo_retention" {
  description = "How long Tempo keeps traces (a duration, e.g. 168h)."
  type        = string
  default     = "168h"
}

variable "otel_trace_sample_ratio" {
  description = "Share of new traces auto-instrumented apps record, 0 to 1 (child spans follow their parent's decision)."
  type        = number
  default     = 1

  validation {
    condition     = var.otel_trace_sample_ratio >= 0 && var.otel_trace_sample_ratio <= 1
    error_message = "otel_trace_sample_ratio must be between 0 and 1."
  }
}
