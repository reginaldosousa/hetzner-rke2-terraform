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
