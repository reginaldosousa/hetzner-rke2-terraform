variable "hcloud_token" {
  description = "Hetzner Cloud API token (read/write). Also handed to the CCM, CSI driver and Karpenter."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.hcloud_token) == 64
    error_message = "hcloud_token must be a 64-character Hetzner Cloud API token."
  }
}

variable "cluster_name" {
  description = "Name prefix for all resources. Karpenter tags the servers it manages with it."
  type        = string
  default     = "rke2"

  # Used in hcloud resource names, label values and Kubernetes labels.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,22}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 2-24 chars of lowercase letters, digits and '-', starting with a letter."
  }
}

variable "location" {
  description = "Hetzner location for all servers (nbg1, fsn1, hel1 are in eu-central)."
  type        = string
  default     = "nbg1"

  validation {
    condition     = contains(["fsn1", "nbg1", "hel1", "ash", "hil", "sin"], var.location)
    error_message = "location must be a Hetzner location (fsn1, nbg1, hel1, ash, hil, sin). Note: us-east/us-west/eu-central are network zones, not locations."
  }

  # Cross-variable validation (Terraform >= 1.9).
  validation {
    condition = lookup({
      fsn1 = "eu-central", nbg1 = "eu-central", hel1 = "eu-central",
      ash  = "us-east", hil = "us-west", sin = "ap-southeast",
    }, var.location, "") == var.network_zone
    error_message = "location must be in network_zone (fsn1/nbg1/hel1 = eu-central, ash = us-east, hil = us-west, sin = ap-southeast)."
  }
}

variable "network_zone" {
  description = "Network zone that contains var.location."
  type        = string
  default     = "eu-central"

  validation {
    condition     = contains(["eu-central", "us-east", "us-west", "ap-southeast"], var.network_zone)
    error_message = "network_zone must be one of eu-central, us-east, us-west, ap-southeast."
  }
}

variable "network_cidr" {
  description = "CIDR of the private network (the 'VPC')."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.network_cidr, 0)) && !(cidrhost("${cidrhost("10.42.0.0/16", 0)}/${split("/", var.network_cidr)[1]}", 0) == cidrhost(var.network_cidr, 0) || cidrhost("${cidrhost(var.network_cidr, 0)}/${split("/", "10.42.0.0/16")[1]}", 0) == cidrhost("10.42.0.0/16", 0)) && !(cidrhost("${cidrhost("10.43.0.0/16", 0)}/${split("/", var.network_cidr)[1]}", 0) == cidrhost(var.network_cidr, 0) || cidrhost("${cidrhost(var.network_cidr, 0)}/${split("/", "10.43.0.0/16")[1]}", 0) == cidrhost("10.43.0.0/16", 0))
    error_message = "network_cidr must be a valid CIDR that does not overlap RKE2's pod (10.42.0.0/16) or service (10.43.0.0/16) ranges."
  }
}

variable "subnet_cidr" {
  description = "Subnet for all servers. Must be inside network_cidr."
  type        = string
  default     = "10.0.1.0/24"

  validation {
    condition = (
      tonumber(split("/", var.subnet_cidr)[1]) >= tonumber(split("/", var.network_cidr)[1]) &&
      cidrhost("${cidrhost(var.subnet_cidr, 0)}/${split("/", var.network_cidr)[1]}", 0) == cidrhost(var.network_cidr, 0)
    )
    error_message = "subnet_cidr must be inside network_cidr."
  }
}

variable "vpn_cidr" {
  description = "Address range for WireGuard clients. Must NOT overlap network_cidr."
  type        = string
  default     = "10.200.0.0/24"

  validation {
    condition = (
      can(cidrhost(var.vpn_cidr, 0)) && !(cidrhost("${cidrhost(var.network_cidr, 0)}/${split("/", var.vpn_cidr)[1]}", 0) == cidrhost(var.vpn_cidr, 0) || cidrhost("${cidrhost(var.vpn_cidr, 0)}/${split("/", var.network_cidr)[1]}", 0) == cidrhost(var.network_cidr, 0)) &&
      !(cidrhost("${cidrhost("10.42.0.0/16", 0)}/${split("/", var.vpn_cidr)[1]}", 0) == cidrhost(var.vpn_cidr, 0) || cidrhost("${cidrhost(var.vpn_cidr, 0)}/${split("/", "10.42.0.0/16")[1]}", 0) == cidrhost("10.42.0.0/16", 0)) && !(cidrhost("${cidrhost("10.43.0.0/16", 0)}/${split("/", var.vpn_cidr)[1]}", 0) == cidrhost(var.vpn_cidr, 0) || cidrhost("${cidrhost(var.vpn_cidr, 0)}/${split("/", "10.43.0.0/16")[1]}", 0) == cidrhost("10.43.0.0/16", 0))
    )
    error_message = "vpn_cidr must not overlap network_cidr or RKE2's pod/service ranges (10.42.0.0/16, 10.43.0.0/16)."
  }
}

variable "vpn_port" {
  description = "UDP port WireGuard listens on."
  type        = number
  default     = 51820

  validation {
    condition     = var.vpn_port >= 1 && var.vpn_port <= 65535 && floor(var.vpn_port) == var.vpn_port
    error_message = "vpn_port must be an integer between 1 and 65535."
  }
}

variable "vpn_clients" {
  description = "VPN clients: name => host number in vpn_cidr (10 => .10). A key pair and a ready-to-use config is generated for each. Host numbers are explicit so removing a client never renumbers the others."
  type        = map(number)
  default     = { laptop = 10 }

  validation {
    condition     = length(distinct(values(var.vpn_clients))) == length(var.vpn_clients)
    error_message = "Each VPN client needs a unique host number."
  }

  validation {
    # .0 network, .1 gateway, last = broadcast.
    condition = alltrue([
      for n in values(var.vpn_clients) :
      floor(n) == n && n >= 2 && n < pow(2, 32 - tonumber(split("/", var.vpn_cidr)[1])) - 1
    ])
    error_message = "VPN client host numbers must be integers from 2 to the last usable host of vpn_cidr (.1 is the gateway)."
  }
}

variable "ssh_public_key" {
  description = "SSH public key installed on every server (gateway, masters, workers)."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+", var.ssh_public_key))
    error_message = "ssh_public_key must be an OpenSSH public key (ssh-ed25519 / ssh-rsa / ecdsa-sha2-*)."
  }
}

variable "image" {
  description = "OS image for gateway and masters."
  type        = string
  default     = "ubuntu-24.04"
}

variable "gateway_server_type" {
  description = "Server type for the VPN/NAT/HAProxy gateway. WireGuard + NAT + HAProxy fit easily in 2GB."
  type        = string
  default     = "cax11"
}

variable "master_server_type" {
  description = "Server type for the 3 RKE2 server nodes. cax11 (2c/4GB arm64) meets the RKE2 server minimum; go bigger past ~50 workers."
  type        = string
  default     = "cax11"
}

variable "rke2_install_sha256" {
  description = "sha256 of install.sh at the rke2_version tag. Update it with rke2_version: curl -sfL https://raw.githubusercontent.com/rancher/rke2/<version with + as %2B>/install.sh | shasum -a 256"
  type        = string
  default     = "42983c86d1da64a92061d83afb57630cedd69241989f1b0673f3db6c3d92ee6b"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.rke2_install_sha256))
    error_message = "rke2_install_sha256 must be a hex sha256."
  }
}

variable "rke2_version" {
  description = "RKE2 release installed on masters and Karpenter workers (keep them equal)."
  type        = string
  default     = "v1.36.5+rke2r1"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+\\+rke2r[0-9]+$", var.rke2_version))
    error_message = "rke2_version must look like v1.36.5+rke2r1."
  }
}

variable "ccm_chart_version" {
  description = "hcloud-cloud-controller-manager Helm chart version."
  type        = string
  default     = "1.39.2"
}

variable "csi_chart_version" {
  description = "hcloud-csi Helm chart version."
  type        = string
  default     = "2.24.1"
}

variable "protect" {
  description = "Enable Hetzner delete/rebuild protection on the masters (etcd), the reserved gateway IP and the network. Set false, apply, then replace/destroy; set back to true afterwards."
  type        = bool
  default     = true
}

variable "gateway_sync" {
  description = "Push gateway config changes during apply (fail-closed: apply fails if the push fails). Needs the VPN up; set false only for the very first bootstrap apply, before a VPN config exists."
  type        = bool
  default     = true
}

variable "oidc_issuer_url" {
  description = "Public URL of Pocket ID (terraform/cluster deploys it there), e.g. https://auth.example.com. It is the OIDC issuer the kube-apiserver trusts."
  type        = string

  validation {
    condition     = can(regex("^https://[a-z0-9.-]+$", var.oidc_issuer_url))
    error_message = "oidc_issuer_url must be https://<host>, with no path or trailing slash (it must match the token's iss exactly)."
  }
}

variable "oidc_client_id" {
  description = "Client ID of the kubectl client created in Pocket ID. Empty keeps OIDC off on the kube-apiserver (Pocket ID must exist first)."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]*$", var.oidc_client_id))
    error_message = "oidc_client_id is the client ID Pocket ID shows (a UUID)."
  }
}

variable "headscale_hostname" {
  description = "Public name of Headscale on the gateway, e.g. vpn.example.com. Its A record must point at the gateway's IP before Headscale is enabled (ACME). Empty disables Headscale."
  type        = string
  default     = ""

  validation {
    condition     = var.headscale_hostname == "" || can(regex("^[a-z0-9.-]+$", var.headscale_hostname))
    error_message = "headscale_hostname is a bare host name, e.g. vpn.example.com."
  }
}

variable "headscale_oidc_client_id" {
  description = "Client ID of Headscale's Pocket ID client (terraform/identity output headscale_oidc_client_id)."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]*$", var.headscale_oidc_client_id))
    error_message = "headscale_oidc_client_id is the client ID Pocket ID shows."
  }
}

variable "headscale_oidc_client_secret" {
  description = "Secret of Headscale's Pocket ID client (terraform/identity output headscale_oidc_client_secret). Headscale is enabled once this and headscale_hostname are set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "headscale_vpn_group" {
  description = "Pocket ID group whose members may log in to the tailnet."
  type        = string
  default     = "vpn"
}

variable "headscale_node_expiry" {
  description = "How long a tailnet login lasts before the user must sign in again (Go duration)."
  type        = string
  default     = "720h"
}

variable "headscale_version" {
  description = "Headscale release installed on the gateway."
  type        = string
  default     = "0.29.6"
}

variable "headscale_deb_sha256" {
  description = "sha256 of headscale_<version>_linux_arm64.deb (checksums.txt of the release); the gateway is arm64."
  type        = string
  default     = "077467b12ba2122086db434335fadfa8deee4dbddacb1f959eecc6d7d10b81d4"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.headscale_deb_sha256))
    error_message = "headscale_deb_sha256 must be a 64-character hex sha256."
  }
}

variable "tailscale_version" {
  description = "Tailscale client on the gateway (subnet router), from pkgs.tailscale.com."
  type        = string
  default     = "1.104.2"
}
