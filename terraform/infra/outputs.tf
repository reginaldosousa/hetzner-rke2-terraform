output "gateway_private_ip" {
  description = "Gateway address inside the private network (SSH over the VPN)."
  value       = local.gateway_ip
}

output "gateway_known_hosts" {
  description = "known_hosts line pinning the gateway's SSH host key (used by scripts/sync-gateway.sh)."
  value       = local.gateway_known_hosts
}

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
  description = "Cluster name; prefixes resource names and scopes Karpenter-managed servers."
  value       = var.cluster_name
}

output "location" {
  description = "Hetzner location of the gateway and masters."
  value       = var.location
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
  description = "Private IPs of the RKE2 server nodes (master-1..3)."
  value       = local.master_ips
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
    rke2_install_url       = local.rke2_install_url
    rke2_install_sha256    = var.rke2_install_sha256
    private_network_script = local.private_network_script
  })
}

output "network_cidr" {
  description = "Private network range (e.g. trusted source of PROXY protocol from hcloud LBs)."
  value       = var.network_cidr
}

output "master_config_files" {
  description = "Desired RKE2 config files on the masters (path => content), pushed by scripts/sync-masters.sh."
  value       = local.master_files
}

output "etcd_s3_config_secret" {
  description = "kube-system Secret the masters read etcd snapshot S3 settings from (created by terraform/cluster)."
  value       = local.etcd_s3_config_secret
}

output "gateway_config_files" {
  description = "Desired gateway config files (path => content), pushed by scripts/sync-gateway.sh."
  sensitive   = true
  value       = local.gateway_files
}

output "oidc_issuer_url" {
  description = "Pocket ID's public URL; terraform/cluster deploys it there."
  value       = var.oidc_issuer_url
}

output "headscale_url" {
  description = "Headscale's URL (empty when not configured); terraform/identity points its OIDC client's callback here."
  value       = var.headscale_hostname == "" ? "" : "https://${var.headscale_hostname}"
}

output "internal_domain" {
  description = "Private DNS zone answered by dnsmasq on the gateway for VPN clients (docs/adr/0027)."
  value       = local.internal_domain
}

output "internal_ingress_ip" {
  description = "Private IP the CCM gives the internal (private-only) ingress LB; every name under internal_domain resolves to it."
  value       = local.internal_ingress_ip
}
