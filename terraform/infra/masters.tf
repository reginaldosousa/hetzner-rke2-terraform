# Shared secret every RKE2 server and agent uses to join the cluster.
resource "random_password" "rke2_token" {
  length  = 48
  special = false
}

locals {
  private_network_script = templatefile("${path.module}/templates/private-network.sh.tftpl", {
    network_cidr      = var.network_cidr
    network_router_ip = local.network_router_ip
  })
}

resource "hcloud_placement_group" "masters" {
  name = "${var.cluster_name}-masters"
  type = "spread"
}

resource "hcloud_server" "master" {
  count = 3

  name               = "${var.cluster_name}-master-${count.index + 1}"
  server_type        = var.master_server_type
  image              = var.image
  location           = var.location
  ssh_keys           = [hcloud_ssh_key.default.id]
  placement_group_id = hcloud_placement_group.masters.id

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.main.id
    ip         = local.master_ips[count.index]
  }

  # master-1 initialises etcd; the others join through the load balancer.
  user_data = templatefile("${path.module}/templates/master-cloud-init.yaml.tftpl", {
    bootstrap              = count.index == 0
    token                  = random_password.rke2_token.result
    node_ip                = local.master_ips[count.index]
    lb_ip                  = local.lb_ip
    rke2_version           = var.rke2_version
    private_network_script = local.private_network_script
    hcloud_token           = var.hcloud_token
    network_id             = hcloud_network.main.id
    location               = var.location
    ccm_version            = var.ccm_chart_version
    csi_version            = var.csi_chart_version
  })

  labels = {
    cluster = var.cluster_name
    role    = "master"
  }

  lifecycle {
    # cloud-init only runs on first boot; don't recreate masters when it changes.
    ignore_changes = [user_data, image]
  }

  depends_on = [
    hcloud_network_subnet.nodes,
    hcloud_network_route.default_via_gateway,
    hcloud_server.gateway,
  ]
}
