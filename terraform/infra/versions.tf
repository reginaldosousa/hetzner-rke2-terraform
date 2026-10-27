terraform {
  required_version = ">= 1.9, < 2.0" # 1.9: cross-variable validation

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
    wireguard = {
      source  = "OJFord/wireguard"
      version = "~> 0.4"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}
