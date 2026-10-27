#!/usr/bin/env bash
# Record the masters' SSH host keys in ./master_known_hosts, read through the
# gateway (whose host key is pinned by Terraform) over the private network, so
# get-kubeconfig.sh and sync-masters.sh never trust a master on first use.
# Rerun after a master is replaced. Requires the WireGuard tunnel to be up.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
infra="$repo_root/terraform/infra"
out="$repo_root/master_known_hosts"
timeout="${PIN_TIMEOUT_SECONDS:-600}"

gw_ip="$(terraform -chdir="$infra" output -raw gateway_private_ip)"
master_ips="$(terraform -chdir="$infra" output -json master_ips | jq -r '.[]')"
want=$(wc -w <<<"$master_ips")

gw_known_hosts="$(mktemp)"
trap 'rm -f "$gw_known_hosts"' EXIT
terraform -chdir="$infra" output -raw gateway_known_hosts > "$gw_known_hosts"

# sshd comes up a few seconds after a master boots.
deadline=$(( $(date +%s) + timeout ))
while :; do
  # shellcheck disable=SC2086 # word-split the IP list on purpose
  keys="$(ssh -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$gw_known_hosts" \
    "root@$gw_ip" ssh-keyscan -T 5 -t ed25519 $master_ips 2>/dev/null || true)"
  got=$(grep -c ssh-ed25519 <<<"$keys" || true)
  [ "$got" -eq "$want" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "ERROR: got $got of $want master host keys after ${timeout}s." >&2
    exit 1
  fi
  echo "waiting for sshd on the masters ($got/$want) ..."
  sleep 10
done

umask 077
printf '%s\n' "$keys" > "$out"
echo "Wrote $out"
