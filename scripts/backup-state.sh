#!/usr/bin/env bash
# R2 has no object versioning, so keep our own state history.
# Pulls each root's current remote state into state-backups/<root>/ (git-ignored,
# contains secrets) and keeps the newest $KEEP copies. Run after every apply.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
keep="${KEEP:-30}"
ts="$(date +%Y%m%d-%H%M%S)"
umask 077

for root in infra cluster; do
  dir="$repo_root/state-backups/$root"
  mkdir -p "$dir"
  out="$dir/$ts.tfstate"
  terraform -chdir="$repo_root/terraform/$root" state pull > "$out"
  serial="$(jq -r .serial "$out")"
  echo "backed up $root (serial $serial) -> ${out#"$repo_root"/}"
  # Prune oldest beyond $keep (portable: no GNU head -n -N / xargs -r).
  find "$dir" -name '*.tfstate' -type f | sort -r | tail -n "+$((keep + 1))" |
    while IFS= read -r old; do rm -f "$old"; done
done
