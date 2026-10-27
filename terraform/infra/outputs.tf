output "gateway_public_ip" {
  description = "Public IPv4 of the VPN gateway (the only public endpoint)."
  value       = hcloud_server.gateway.ipv4_address
}

output "vpn_client_configs" {
  description = "WireGuard config per client. Save with: terraform output -json vpn_client_configs | jq -r .laptop > wg/laptop.conf"
  sensitive   = true
  value = {
    for peer in local.vpn_peers : peer.name => <<-EOT
      [Interface]
      PrivateKey = ${wireguard_asymmetric_key.client[peer.name].private_key}
      Address    = ${peer.ip}/32

      [Peer]
      PublicKey           = ${wireguard_asymmetric_key.gateway.public_key}
      Endpoint            = ${hcloud_server.gateway.ipv4_address}:${var.vpn_port}
      AllowedIPs          = ${var.network_cidr}, ${var.vpn_cidr}
      PersistentKeepalive = 25
    EOT
  }
}

output "cluster_name" {
  value = var.cluster_name
}

output "location" {
  value = var.location
}

output "network_id" {
  description = "Private network ID (HCloudNodeClass.spec.networkID)."
  value       = hcloud_network.main.id
}

output "ssh_key_id" {
  description = "SSH key installed on Karpenter workers."
  value       = hcloud_ssh_key.default.id
}

output "control_plane_ip" {
  description = "HAProxy on the gateway: kube-apiserver (:6443) and RKE2 join (:9345)."
  value       = local.control_plane_ip
}

output "master_ips" {
  value = local.master_ips
}

output "hcloud_token" {
  description = "Passed through to the cluster root, which creates the kube-system/hcloud Secret."
  value       = var.hcloud_token
  sensitive   = true
}

output "worker_user_data" {
  description = "cloud-init that joins a Karpenter worker as an RKE2 agent."
  sensitive   = true
  value = templatefile("${path.module}/templates/worker-userdata.yaml.tftpl", {
    control_plane_ip       = local.control_plane_ip
    token                  = random_password.rke2_agent_token.result
    rke2_version           = var.rke2_version
    private_network_script = local.private_network_script
  })
}

output "network_cidr" {
  description = "Private network range (e.g. trusted source of PROXY protocol from hcloud LBs)."
  value       = var.network_cidr
}
