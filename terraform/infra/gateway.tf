resource "hcloud_ssh_key" "default" {
  name       = var.cluster_name
  public_key = var.ssh_public_key
}

locals {
  vpn_gateway_ip = cidrhost(var.vpn_cidr, 1)
  vpn_peers = [
    for i, name in var.vpn_clients : {
      name       = name
      ip         = cidrhost(var.vpn_cidr, 10 + i)
      public_key = wireguard_asymmetric_key.client[name].public_key
    }
  ]
}

# Keys live in Terraform state, so the state must be treated as a secret.
resource "wireguard_asymmetric_key" "gateway" {}

resource "wireguard_asymmetric_key" "client" {
  for_each = toset(var.vpn_clients)
}

# The only inbound traffic allowed from the internet is WireGuard.
# SSH to the gateway itself goes through the tunnel.
resource "hcloud_firewall" "gateway" {
  name = "${var.cluster_name}-gateway"

  rule {
    direction  = "in"
    protocol   = "udp"
    port       = tostring(var.vpn_port)
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

# Reserved separately from the server so the VPN endpoint (and every client
# config) survives a gateway rebuild.
resource "hcloud_primary_ip" "gateway" {
  name          = "${var.cluster_name}-gateway"
  type          = "ipv4"
  location      = var.location
  assignee_type = "server"
  auto_delete   = false

  labels = {
    cluster = var.cluster_name
  }
}

resource "hcloud_server" "gateway" {
  name         = "${var.cluster_name}-gateway"
  server_type  = var.gateway_server_type
  image        = var.image
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.default.id]
  firewall_ids = [hcloud_firewall.gateway.id]

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.gateway.id
    ipv6_enabled = true
  }

  network {
    network_id = hcloud_network.main.id
    ip         = local.gateway_ip
  }

  user_data = templatefile("${path.module}/templates/gateway-cloud-init.yaml.tftpl", {
    vpn_gateway_ip = local.vpn_gateway_ip
    vpn_prefix     = split("/", var.vpn_cidr)[1]
    vpn_port       = var.vpn_port
    vpn_cidr       = var.vpn_cidr
    network_cidr   = var.network_cidr
    private_key    = wireguard_asymmetric_key.gateway.private_key
    peers          = local.vpn_peers
  })

  labels = {
    cluster = var.cluster_name
    role    = "gateway"
  }

  depends_on = [hcloud_network_subnet.nodes]
}
