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

# Headscale (docs/adr/0025) runs once its Pocket ID client exists
# (terraform/identity output headscale_oidc_client_secret).
locals {
  # Whether the secret is set is not itself secret; keeps plans readable.
  headscale    = var.headscale_hostname != "" && nonsensitive(var.headscale_oidc_client_secret != "")
  tailnet_cidr = "100.64.0.0/10" # Tailscale's CGNAT range; clients expect it
  vpn_ifaces   = local.headscale ? "\"wg0\", \"tailscale0\"" : "\"wg0\""
  vpn_cidrs    = local.headscale ? "${var.vpn_cidr}, ${local.tailnet_cidr}" : var.vpn_cidr
  # Litestream to R2 (docs/adr/0026) once terraform/cluster made the bucket.
  headscale_backup = local.headscale && nonsensitive(var.headscale_backup != null)

  headscale_files = !local.headscale ? {} : {
    "/etc/headscale/config.yaml" = templatefile("${path.module}/templates/gateway/headscale-config.yaml.tftpl", {
      hostname        = var.headscale_hostname
      tailnet_cidr    = local.tailnet_cidr
      region_code     = var.cluster_name
      public_ipv4     = hcloud_primary_ip.gateway.ip_address
      node_expiry     = var.headscale_node_expiry
      oidc_issuer_url = var.oidc_issuer_url
      oidc_client_id  = var.headscale_oidc_client_id
      vpn_group       = var.headscale_vpn_group
      internal_domain = local.internal_domain
      gateway_ip      = local.gateway_ip
    })
    "/etc/headscale/policy.hujson" = templatefile("${path.module}/templates/gateway/headscale-policy.hujson.tftpl", {
      network_cidr = var.network_cidr
      gateway_ip   = local.gateway_ip
      ingress_ip   = local.internal_ingress_ip
    })
    "/etc/headscale/oidc_client_secret" = var.headscale_oidc_client_secret
    # Headscale's own file format; it trims surrounding whitespace on read.
    "/var/lib/headscale/noise_private.key"       = "privkey:${random_bytes.headscale_noise_key.hex}"
    "/var/lib/headscale/derp_server_private.key" = "privkey:${random_bytes.headscale_derp_key.hex}"
    "/usr/local/sbin/headscale-install.sh" = templatefile("${path.module}/templates/gateway/headscale-install.sh.tftpl", {
      headscale_version    = var.headscale_version
      headscale_deb_sha256 = var.headscale_deb_sha256
      tailscale_version    = var.tailscale_version
      backup               = local.headscale_backup
      litestream_version   = var.litestream_version
      litestream_sha256    = var.litestream_deb_sha256
    })
    "/usr/local/sbin/tailnet-join.sh" = templatefile("${path.module}/templates/gateway/tailnet-join.sh.tftpl", {
      hostname     = var.headscale_hostname
      network_cidr = var.network_cidr
    })
    "/etc/systemd/system/tailnet-join.service" = file("${path.module}/templates/gateway/tailnet-join.service")
  }

  headscale_backup_files = !local.headscale_backup ? {} : {
    "/etc/headscale/litestream.yml" = templatefile("${path.module}/templates/gateway/litestream.yml.tftpl", {
      endpoint          = var.headscale_backup.endpoint
      bucket            = var.headscale_backup.bucket
      path              = "${var.cluster_name}/headscale"
      access_key_id     = var.headscale_backup.access_key_id
      secret_access_key = var.headscale_backup.secret_access_key
    })
    "/etc/systemd/system/headscale-backup.service" = file("${path.module}/templates/gateway/headscale-backup.service")
  }
}

locals {
  gateway_known_hosts = "${local.gateway_ip} ${trimspace(tls_private_key.gateway_host.public_key_openssh)}"
}

# Everything on the gateway that can change after first boot. Rendered once:
# cloud-init writes it on first boot, scripts/sync-gateway.sh pushes updates.
locals {
  gateway_files = merge(local.headscale_files, local.headscale_backup_files, {
    "/etc/wireguard/wg0.conf" = templatefile("${path.module}/templates/gateway/wg0.conf.tftpl", {
      vpn_gateway_ip = local.vpn_gateway_ip
      vpn_prefix     = split("/", var.vpn_cidr)[1]
      vpn_port       = var.vpn_port
      private_key    = wireguard_asymmetric_key.gateway.private_key
      peers          = local.vpn_peers
    })
    "/etc/nftables.conf" = templatefile("${path.module}/templates/gateway/nftables.conf.tftpl", {
      network_cidr = var.network_cidr
      vpn_cidrs    = local.vpn_cidrs
      vpn_ifaces   = local.vpn_ifaces
      vpn_port     = var.vpn_port
      headscale    = local.headscale
      tailnet_cidr = local.tailnet_cidr
      gateway_ip   = local.gateway_ip
      ingress_ip   = local.internal_ingress_ip
    })
    "/etc/haproxy/haproxy.cfg" = templatefile("${path.module}/templates/gateway/haproxy.cfg.tftpl", {
      gateway_ip = local.gateway_ip
      master_ips = local.master_ips
    })
    "/etc/dnsmasq-internal.conf" = templatefile("${path.module}/templates/gateway/internal-dns.conf.tftpl", {
      domain     = local.internal_domain
      gateway_ip = local.gateway_ip
      ingress_ip = local.internal_ingress_ip
    })
    "/etc/systemd/system/internal-dns.service" = file("${path.module}/templates/gateway/internal-dns.service")
  })
}

# The gateway's SSH host key, so scripts/sync-gateway.sh can pin it
# (StrictHostKeyChecking=yes) instead of trusting whatever answers at the
# gateway IP on first contact, e.g. a host on a foreign LAN while the VPN is down.
resource "tls_private_key" "gateway_host" {
  algorithm = "ED25519"
}

# Headscale's Noise (control protocol) and DERP server keys, kept in Terraform
# like the host key so a rebuilt gateway presents the same server to every
# client (docs/adr/0026). sync-gateway.sh refuses to overwrite a live key that
# differs: import the running gateway's keys before the first apply.
resource "random_bytes" "headscale_noise_key" {
  length = 32
}

resource "random_bytes" "headscale_derp_key" {
  length = 32
}

# Keys live in Terraform state, so the state must be treated as a secret.
resource "wireguard_asymmetric_key" "gateway" {}

resource "wireguard_asymmetric_key" "client" {
  for_each = var.vpn_clients
}

# Inbound from the internet: WireGuard, and with Headscale its HTTPS/DERP
# port, STUN and tailscaled's direct path. SSH goes through a tunnel.
resource "hcloud_firewall" "gateway" {
  name = "${var.cluster_name}-gateway"

  rule {
    direction  = "in"
    protocol   = "udp"
    port       = tostring(var.vpn_port)
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  dynamic "rule" {
    for_each = local.headscale ? [["tcp", "443"], ["udp", "3478"], ["udp", "41641"]] : []
    content {
      direction  = "in"
      protocol   = rule.value[0]
      port       = rule.value[1]
      source_ips = ["0.0.0.0/0", "::/0"]
    }
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
    files            = local.gateway_files
    host_private_key = tls_private_key.gateway_host.private_key_openssh
    host_public_key  = tls_private_key.gateway_host.public_key_openssh
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
      GATEWAY_HOST        = local.gateway_ip
      GATEWAY_FILES_JSON  = jsonencode(local.gateway_files)
      GATEWAY_KNOWN_HOSTS = local.gateway_known_hosts
      SYNC_WAIT_SECONDS   = "180"
    }
  }
}
