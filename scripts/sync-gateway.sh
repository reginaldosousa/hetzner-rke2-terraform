#!/usr/bin/env bash
# Push the gateway's config (WireGuard peers, nftables NAT, HAProxy) in place,
# instead of rebuilding the server. Run after `terraform apply` in
# terraform/infra whenever vpn_clients, CIDRs or master IPs change.
# Requires the WireGuard tunnel to be up.
#
#   scripts/sync-gateway.sh --dry-run   # show what would change
#   scripts/sync-gateway.sh             # validate on the gateway, then activate
set -euo pipefail

dry_run=false
[ "${1:-}" = "--dry-run" ] && dry_run=true

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
infra="$repo_root/terraform/infra"
gw="root@$(terraform -chdir="$infra" output -raw gateway_private_ip)"
ssh_gw() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$gw" "$@"; }

local_dir="$(mktemp -d)"
trap 'rm -rf "$local_dir"' EXIT
chmod 700 "$local_dir"

files_json="$(terraform -chdir="$infra" output -json gateway_config_files)"
stage=/root/.gateway-sync   # same basenames: wg-quick needs <iface>.conf
changed=()

for path in $(jq -r 'keys[]' <<<"$files_json"); do
  file="$local_dir/$(basename "$path")"
  jq -j --arg p "$path" '.[$p]' <<<"$files_json" > "$file"
  want="$(shasum -a 256 < "$file" | cut -d' ' -f1)"
  have="$(ssh_gw "sha256sum < '$path' 2>/dev/null | cut -d' ' -f1" || true)"
  if [ "$want" = "$have" ]; then
    echo "unchanged  $path"
    continue
  fi
  echo "changed    $path"
  diff <(ssh_gw "cat '$path'" 2>/dev/null) "$file" \
    | sed -E 's/(PrivateKey *= *).*/\1<redacted>/' | sed 's/^/    /' || true
  changed+=("$path")
done

[ ${#changed[@]} -eq 0 ] && { echo "Gateway is in sync."; exit 0; }
$dry_run && { echo "Dry run: nothing pushed."; exit 0; }

ssh_gw "rm -rf $stage && install -d -m 700 $stage"
for path in "${changed[@]}"; do
  # Via stdin, so secrets never appear in argv or logs.
  ssh_gw "umask 077; cat > $stage/$(basename "$path")" < "$local_dir/$(basename "$path")"
done

# Validate every staged file first; activate only if all pass. WireGuard goes
# last: `wg syncconf` keeps existing tunnels, including this SSH session.
ssh_gw bash -s -- "${changed[@]}" <<'REMOTE'
set -euo pipefail
stage=/root/.gateway-sync
has() { printf '%s\n' "${CHANGED[@]}" | grep -qx "$1"; }
CHANGED=("$@")

has /etc/nftables.conf       && nft -c -f $stage/nftables.conf
has /etc/haproxy/haproxy.cfg && haproxy -q -c -f $stage/haproxy.cfg
has /etc/wireguard/wg0.conf  && wg-quick strip $stage/wg0.conf >/dev/null

if has /etc/nftables.conf; then
  install -m 600 $stage/nftables.conf /etc/nftables.conf && nft -f /etc/nftables.conf
  echo "activated  /etc/nftables.conf (atomic ruleset swap)"
fi
if has /etc/haproxy/haproxy.cfg; then
  install -m 600 $stage/haproxy.cfg /etc/haproxy/haproxy.cfg && systemctl reload haproxy
  echo "activated  /etc/haproxy/haproxy.cfg (graceful reload)"
fi
if has /etc/wireguard/wg0.conf; then
  install -m 600 $stage/wg0.conf /etc/wireguard/wg0.conf
  wg syncconf wg0 <(wg-quick strip wg0)
  echo "activated  /etc/wireguard/wg0.conf (wg syncconf, tunnels kept)"
fi
rm -rf $stage
REMOTE
