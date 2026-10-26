#!/usr/bin/env bash
# Fetch the admin kubeconfig from master-1 over the VPN and point it at the
# private load balancer. Requires the WireGuard tunnel to be up.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
infra="$repo_root/terraform/infra"
out="$repo_root/kubeconfig"

master_ip="$(terraform -chdir="$infra" output -json master_ips | jq -r '.[0]')"
lb_ip="$(terraform -chdir="$infra" output -raw control_plane_ip)"

# RKE2 writes the kubeconfig a minute or two after first boot.
until ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@$master_ip" \
  test -f /etc/rancher/rke2/rke2.yaml; do
  echo "waiting for RKE2 on $master_ip ..."
  sleep 10
done

ssh "root@$master_ip" cat /etc/rancher/rke2/rke2.yaml \
  | sed "s#https://127.0.0.1:6443#https://$lb_ip:6443#" > "$out"
chmod 600 "$out"

echo "Wrote $out"
echo "  export KUBECONFIG=$out && kubectl get nodes -o wide"
