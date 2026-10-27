#!/usr/bin/env bash
# Fetch the admin kubeconfig from master-1 over the VPN and point it at the
# control-plane endpoint (HAProxy on the gateway). Requires the WireGuard tunnel to be up.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
infra="$repo_root/terraform/infra"
out="$repo_root/kubeconfig"

master_ip="$(terraform -chdir="$infra" output -json master_ips | jq -r '.[0]')"
cp_ip="$(terraform -chdir="$infra" output -raw control_plane_ip)"

# Host keys come from pin-master-host-keys.sh (read through the pinned gateway).
known_hosts="$repo_root/master_known_hosts"
[ -s "$known_hosts" ] || "$repo_root/scripts/pin-master-host-keys.sh"
ssh_m() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" "$@"
}

# RKE2 writes the kubeconfig a minute or two after first boot.
until ssh_m "root@$master_ip" test -f /etc/rancher/rke2/rke2.yaml; do
  echo "waiting for RKE2 on $master_ip ..."
  sleep 10
done

ssh_m "root@$master_ip" cat /etc/rancher/rke2/rke2.yaml \
  | sed "s#https://127.0.0.1:6443#https://$cp_ip:6443#" > "$out"
chmod 600 "$out"

echo "Wrote $out"
echo "  export KUBECONFIG=$out && kubectl get nodes -o wide"
