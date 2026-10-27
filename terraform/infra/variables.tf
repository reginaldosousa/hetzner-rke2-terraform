variable "hcloud_token" {
  description = "Hetzner Cloud API token (read/write). Also handed to the CCM, CSI driver and Karpenter."
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Name prefix for all resources. Karpenter tags the servers it manages with it."
  type        = string
  default     = "rke2"
}

variable "location" {
  description = "Hetzner location for all servers (nbg1, fsn1, hel1 are in eu-central)."
  type        = string
  default     = "nbg1"
}

variable "network_zone" {
  description = "Network zone that contains var.location."
  type        = string
  default     = "eu-central"
}

variable "network_cidr" {
  description = "CIDR of the private network (the 'VPC')."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "Subnet for all servers. Must be inside network_cidr."
  type        = string
  default     = "10.0.1.0/24"
}

variable "vpn_cidr" {
  description = "Address range for WireGuard clients. Must NOT overlap network_cidr."
  type        = string
  default     = "10.200.0.0/24"
}

variable "vpn_port" {
  description = "UDP port WireGuard listens on."
  type        = number
  default     = 51820
}

variable "vpn_clients" {
  description = "Names of VPN clients. A key pair and a ready-to-use config is generated for each."
  type        = list(string)
  default     = ["laptop"]
}

variable "ssh_public_key" {
  description = "SSH public key installed on every server (gateway, masters, workers)."
  type        = string
}

variable "image" {
  description = "OS image for gateway and masters."
  type        = string
  default     = "ubuntu-24.04"
}

variable "gateway_server_type" {
  description = "Server type for the VPN/NAT/HAProxy gateway. WireGuard + NAT + HAProxy fit easily in 2GB."
  type        = string
  default     = "cpx11"
}

variable "master_server_type" {
  description = "Server type for the 3 RKE2 server nodes. cx23 (2c/4GB) is the RKE2 server minimum; go bigger past ~50 workers."
  type        = string
  default     = "cx23"
}

variable "rke2_version" {
  description = "RKE2 release installed on masters and Karpenter workers (keep them equal)."
  type        = string
  default     = "v1.36.5+rke2r1"
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
