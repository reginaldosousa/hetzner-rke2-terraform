terraform {
  required_version = ">= 1.10, < 2.0" # 1.10: S3 use_lockfile

  required_providers {
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
