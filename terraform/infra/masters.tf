# Server token: only masters know it.
resource "random_password" "rke2_token" {
  length  = 48
  special = false
}

# Agent token: lets a node join as a worker, nothing more.
resource "random_password" "rke2_agent_token" {
  length  = 48
  special = false
}

locals {
  private_network_script = templatefile("${path.module}/templates/private-network.sh.tftpl", {
    network_cidr      = var.network_cidr
    network_router_ip = local.network_router_ip
  })
}

# RKE2 settings that must reach running masters too. cloud-init writes them on
# first boot; scripts/sync-masters.sh pushes changes and restarts one master at
# a time (masters ignore user_data changes). No secrets here.
locals {
  master_files = {
    "/etc/rancher/rke2/pod-security.yaml"                  = file("${path.module}/templates/master/pod-security.yaml")
    "/etc/rancher/rke2/config.yaml.d/10-pod-security.yaml" = file("${path.module}/templates/master/10-pod-security.yaml")
  }
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

  # etcd lives here: block accidental delete/rebuild (also from console/API).
  delete_protection  = var.protect
  rebuild_protection = var.protect

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.main.id
    ip         = local.master_ips[count.index]
  }

  # master-1 initialises etcd; the others join through HAProxy on the gateway.
  user_data = templatefile("${path.module}/templates/master-cloud-init.yaml.tftpl", {
    bootstrap              = count.index == 0
    token                  = random_password.rke2_token.result
    agent_token            = random_password.rke2_agent_token.result
    node_ip                = local.master_ips[count.index]
    control_plane_ip       = local.control_plane_ip
    rke2_version           = var.rke2_version
    private_network_script = local.private_network_script
    location               = var.location
    ccm_version            = var.ccm_chart_version
    csi_version            = var.csi_chart_version
    files                  = local.master_files
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
