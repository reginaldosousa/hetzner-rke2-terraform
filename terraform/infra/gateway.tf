resource "hcloud_ssh_key" "default" {
  name       = var.cluster_name
  public_key = var.ssh_public_key
}

locals {
  vpn_gateway_ip = cidrhost(var.vpn_cidr, 1)
  vpn_peers = [
    for name, host in var.vpn_clients : {
      name       = name
      ip         = cidrhost(var.vpn_cidr, host)
      public_key = wireguard_asymmetric_key.client[name].public_key
    }
  ]
}

# Everything on the gateway that can change after first boot. Rendered once:
# cloud-init writes it on first boot, scripts/sync-gateway.sh pushes updates.
locals {
  gateway_files = {
    "/etc/wireguard/wg0.conf" = templatefile("${path.module}/templates/gateway/wg0.conf.tftpl", {
      vpn_gateway_ip = local.vpn_gateway_ip
      vpn_prefix     = split("/", var.vpn_cidr)[1]
      vpn_port       = var.vpn_port
      private_key    = wireguard_asymmetric_key.gateway.private_key
      peers          = local.vpn_peers
    })
    "/etc/nftables.conf" = templatefile("${path.module}/templates/gateway/nftables.conf.tftpl", {
      network_cidr = var.network_cidr
      vpn_cidr     = var.vpn_cidr
    })
    "/etc/haproxy/haproxy.cfg" = templatefile("${path.module}/templates/gateway/haproxy.cfg.tftpl", {
      gateway_ip = local.gateway_ip
      master_ips = local.master_ips
    })
  }
}

# Keys live in Terraform state, so the state must be treated as a secret.
resource "wireguard_asymmetric_key" "gateway" {}

resource "wireguard_asymmetric_key" "client" {
  for_each = var.vpn_clients
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
  name        = "${var.cluster_name}-gateway"
  type        = "ipv4"
  location    = var.location
  auto_delete = false
  # Losing this address breaks every VPN client config.
  delete_protection = var.protect

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
    files = local.gateway_files
  })

  labels = {
    cluster = var.cluster_name
    role    = "gateway"
  }

  lifecycle {
    # user_data only bootstraps the first boot. VPN peer / HAProxy / NAT
    # changes are pushed in place by scripts/sync-gateway.sh instead of
    # rebuilding the server (which would drop VPN, egress and the API endpoint).
    ignore_changes = [user_data]
  }

  depends_on = [hcloud_network_subnet.nodes]
}

# Fail-closed config push: whenever the gateway's files change (e.g. a VPN
# client is removed) or the gateway is rebuilt, apply runs the sync and FAILS if
# it can't push, so a revoked peer can't silently keep access. A failed push
# taints this resource and the next apply retries.
resource "terraform_data" "gateway_sync" {
  count = var.gateway_sync ? 1 : 0

  triggers_replace = {
    files   = sha256(jsonencode(local.gateway_files))
    gateway = hcloud_server.gateway.id
  }

  provisioner "local-exec" {
    command = "${path.module}/../../scripts/sync-gateway.sh"
    # Passed directly: `terraform output` would still return the previous
    # apply's values here. Sensitive, so Terraform suppresses this output.
    environment = {
      GATEWAY_HOST       = local.gateway_ip
      GATEWAY_FILES_JSON = jsonencode(local.gateway_files)
      SYNC_WAIT_SECONDS  = "180"
    }
  }
}
