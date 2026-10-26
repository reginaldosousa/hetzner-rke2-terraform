# Private-only load balancer in front of the 3 masters. It gives the cluster
# one stable address for the kube-apiserver (6443) and the RKE2 supervisor
# that new nodes join through (9345).
resource "hcloud_load_balancer" "control_plane" {
  name               = "${var.cluster_name}-control-plane"
  load_balancer_type = "lb11"
  location           = var.location

  labels = {
    cluster = var.cluster_name
  }
}

resource "hcloud_load_balancer_network" "control_plane" {
  load_balancer_id        = hcloud_load_balancer.control_plane.id
  network_id              = hcloud_network.main.id
  ip                      = local.lb_ip
  enable_public_interface = false

  depends_on = [hcloud_network_subnet.nodes]
}

resource "hcloud_load_balancer_target" "masters" {
  type             = "label_selector"
  load_balancer_id = hcloud_load_balancer.control_plane.id
  label_selector   = "cluster=${var.cluster_name},role=master"
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.control_plane]
}

resource "hcloud_load_balancer_service" "control_plane" {
  for_each = toset(["6443", "9345"])

  load_balancer_id = hcloud_load_balancer.control_plane.id
  protocol         = "tcp"
  listen_port      = tonumber(each.value)
  destination_port = tonumber(each.value)

  health_check {
    protocol = "tcp"
    port     = tonumber(each.value)
    interval = 10
    timeout  = 5
    retries  = 3
  }
}
