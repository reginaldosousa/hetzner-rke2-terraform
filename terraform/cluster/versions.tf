terraform {
  required_version = ">= 1.10, < 2.0" # 1.10: S3 use_lockfile

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.4"
    }
  }
}

# Reached over the WireGuard tunnel via HAProxy on the gateway (see scripts/get-kubeconfig.sh).
provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes = {
    config_path = var.kubeconfig_path
  }
}

# Used only by Terraform to create R2 buckets and scoped account tokens. It can
# mint tokens, so it never goes into the cluster (external-dns gets its own).
provider "cloudflare" {
  api_token = var.cloudflare_provisioning_api_token
}
