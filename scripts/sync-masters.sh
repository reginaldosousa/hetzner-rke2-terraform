#!/usr/bin/env bash
# Push the masters' RKE2 config files (output master_config_files: Pod Security,
# etcd snapshots) in place and restart rke2-server on one master at a time.
# Masters ignore user_data after first boot, so this is how running masters get
# those changes. Run it after `terraform apply` changes them. Requires the
# WireGuard tunnel to be up.
#
#   scripts/sync-masters.sh --dry-run   # show what would change
#   scripts/sync-masters.sh             # push + rolling restart of changed masters
#
# Stops at the first master that does not come back ready, so a bad config can
# cost at most one of the three etcd members.
set -euo pipefail

dry_run=false
[ "${1:-}" = "--dry-run" ] && dry_run=true

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
infra="$repo_root/terraform/infra"
files_json="$(terraform -chdir="$infra" output -json master_config_files)"
master_ips="$(terraform -chdir="$infra" output -json master_ips | jq -r '.[]')"
ready_timeout="${READY_TIMEOUT_SECONDS:-600}"

local_dir="$(mktemp -d)"
trap 'rm -rf "$local_dir"' EXIT
chmod 700 "$local_dir"

# These files hold no secrets (the S3 credentials live in a Kubernetes Secret),
# so unlike sync-gateway.sh this trusts a master's host key on first use, as
# get-kubeconfig.sh does.
ssh_m() {
  local ip="$1"
  shift
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "root@$ip" "$@"
}

paths="$(jq -r 'keys[]' <<<"$files_json")"
i=0
for path in $paths; do
  jq -j --arg p "$path" '.[$p]' <<<"$files_json" > "$local_dir/$i"
  i=$((i + 1))
done

for ip in $master_ips; do
  echo "== master $ip"
  changed=()
  i=0
  for path in $paths; do
    want="$(shasum -a 256 < "$local_dir/$i" | cut -d' ' -f1)"
    have="$(ssh_m "$ip" "sha256sum < '$path' 2>/dev/null | cut -d' ' -f1" || true)"
    if [ "$want" = "$have" ]; then
      echo "unchanged  $path"
    else
      echo "changed    $path"
      diff <(ssh_m "$ip" "cat '$path'" 2>/dev/null) "$local_dir/$i" | sed 's/^/    /' || true
      changed+=("$i")
    fi
    i=$((i + 1))
  done

  [ ${#changed[@]} -eq 0 ] && continue
  $dry_run && continue

  for idx in "${changed[@]}"; do
    path="$(sed -n "$((idx + 1))p" <<<"$paths")"
    ssh_m "$ip" "umask 077; mkdir -p '$(dirname "$path")' && cat > '$path.new' && mv '$path.new' '$path'" < "$local_dir/$idx"
  done

  echo "restarting rke2-server on $ip ..."
  ssh_m "$ip" systemctl restart rke2-server
  # readyz on the master's own apiserver also covers its etcd member.
  deadline=$(( $(date +%s) + ready_timeout ))
  until ssh_m "$ip" "/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get --raw /readyz" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "ERROR: $ip not ready after ${ready_timeout}s; stopping before the next master." >&2
      echo "Check: ssh root@$ip journalctl -u rke2-server -n 100" >&2
      exit 1
    fi
    sleep 10
  done
  echo "ready      $ip"
done

$dry_run && echo "Dry run: nothing pushed."
exit 0
