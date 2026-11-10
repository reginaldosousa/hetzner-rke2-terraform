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

variable "psmdb_operator_chart_version" {
  description = "Percona psmdb-operator chart version (ADR 0030)."
  type        = string
  default     = "1.23.2"
}

variable "psmdb_db_chart_version" {
  description = "Percona psmdb-db chart version; its crVersion must match the operator."
  type        = string
  default     = "1.23.4"
}

variable "psmdb_image_tag" {
  description = "percona/percona-server-mongodb image tag (multi-arch)."
  type        = string
  default     = "8.0.32-14"
}

variable "pbm_image_tag" {
  description = "percona/percona-backup-mongodb image tag supported by the operator version."
  type        = string
  default     = "2.15.0"
}

variable "mongodb_exporter_version" {
  description = "percona/mongodb_exporter image tag for the metrics sidecar."
  type        = string
  default     = "0.47.1"
}

variable "mongodb_bucket" {
  description = "R2 bucket for Percona Backup for MongoDB (base backups and oplog)."
  type        = string
  default     = "rke2-mongodb"
}

variable "cnpg_chart_version" {
  description = "cloudnative-pg operator chart version (ADR 0031)."
  type        = string
  default     = "0.29.1"
}

variable "cnpg_barman_plugin_chart_version" {
  description = "plugin-barman-cloud chart version; WAL archiving and base backups for CloudNativePG."
  type        = string
  default     = "0.9.0"
}

variable "postgres_bucket" {
  description = "R2 bucket for CloudNativePG backups (one folder per database)."
  type        = string
  default     = "rke2-postgres"
}

variable "redis_operator_chart_version" {
  description = "OT-Container-Kit redis-operator chart version (ADR 0032)."
  type        = string
  default     = "0.27.0"
}

variable "harbor_chart_version" {
  description = "goharbor harbor chart version (ADR 0033). 1.19.4 ships Harbor 2.15 (amd64 only), so harbor_version overrides its images until a 2.16 chart is out."
  type        = string
  default     = "1.19.4"
}

variable "harbor_version" {
  description = "Tag of every goharbor image; v2.16.0 is the first multi-arch release."
  type        = string
  default     = "v2.16.0"
}

variable "harbor_hostname" {
  description = "Harbor's name: public DNS pointing at the private ingress LB (ADR 0033). Must be in one of external_dns_domains and outside the internal domain."
  type        = string
  default     = "harbor.devcomm.com.br"
}

variable "harbor_bucket" {
  description = "R2 bucket for Harbor's image blobs."
  type        = string
  default     = "rke2-harbor"
}

variable "redis_replication_chart_version" {
  description = "OT-Container-Kit redis-replication chart version (RedisReplication CR with Sentinel)."
  type        = string
  default     = "0.17.1"
}

variable "redis_image_tag" {
  description = "quay.io/opstree/redis and redis-sentinel tag. Stay on 7.2.x: the last BSD-licensed Redis (ADR 0032)."
  type        = string
  default     = "v7.2.16"
}

variable "redis_exporter_image_tag" {
  description = "quay.io/opstree/redis-exporter tag for Redis instances."
  type        = string
  default     = "v1.89.0"
}
