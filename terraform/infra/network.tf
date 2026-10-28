locals {
  # Fixed private addresses inside the subnet.
  gateway_ip = cidrhost(var.subnet_cidr, 2)
  # kube-apiserver + RKE2 join endpoint: HAProxy on the gateway (no paid LB).
  control_plane_ip = local.gateway_ip
  master_ips       = [for i in range(3) : cidrhost(var.subnet_cidr, 11 + i)]
  # Private-only ingress LB for internal apps (docs/adr/0027), created by the
  # CCM with this address. The top of the subnet, because servers attached
  # without an IP (Karpenter workers) take the lowest free ones.
  internal_ingress_ip = cidrhost(var.subnet_cidr, -2)
  internal_domain     = var.internal_domain != "" ? var.internal_domain : "${var.cluster_name}.internal"

  # Hetzner's virtual router: first address of the whole network. Private-only
  # servers send their default route here; the network route below then
  # forwards it to our NAT gateway.
  network_router_ip = cidrhost(var.network_cidr, 1)
}

resource "hcloud_network" "main" {
  name              = var.cluster_name
  ip_range          = var.network_cidr
  delete_protection = var.protect
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = var.subnet_cidr
}

# Internet egress for servers without a public IP goes through the gateway.
resource "hcloud_network_route" "default_via_gateway" {
  network_id  = hcloud_network.main.id
  destination = "0.0.0.0/0"
  gateway     = local.gateway_ip
}

# Return path to VPN clients, so nodes can answer them without NAT.
resource "hcloud_network_route" "vpn_clients" {
  network_id  = hcloud_network.main.id
  destination = var.vpn_cidr
  gateway     = local.gateway_ip
}
