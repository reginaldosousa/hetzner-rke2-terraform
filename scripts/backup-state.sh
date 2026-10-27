#!/usr/bin/env bash
# R2 has no object versioning, so keep our own state history.
# Pulls each root's current remote state into state-backups/<root>/ (git-ignored,
# contains secrets) and into backups/<root>/ in the state bucket, so a copy
# survives both a bad state write and the loss of this laptop. Keeps the newest
# $KEEP copies in each place. Run after every apply. REMOTE=0 skips the bucket.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
keep="${KEEP:-30}"
ts="$(date +%Y%m%d-%H%M%S)"
remote="${REMOTE:-1}"
umask 077

# Same bucket and credentials as the backends (terraform/*/backend.tf).
bucket="s3://rke2-tfstate"
s3() {
  aws --profile r2 --region auto \
    --endpoint-url https://9cf4130ce6c67ffa7f69903b7e2e4b15.r2.cloudflarestorage.com s3 "$@"
}

for root in infra cluster identity; do
  dir="$repo_root/state-backups/$root"
  mkdir -p "$dir"
  out="$dir/$ts.tfstate"
  terraform -chdir="$repo_root/terraform/$root" state pull > "$out"
  serial="$(jq -r .serial "$out")"
  echo "backed up $root (serial $serial) -> ${out#"$repo_root"/}"
  # Prune oldest beyond $keep (portable: no GNU head -n -N / xargs -r).
  find "$dir" -name '*.tfstate' -type f | sort -r | tail -n "+$((keep + 1))" |
    while IFS= read -r old; do rm -f "$old"; done

  [ "$remote" = 1 ] || continue
  s3 cp --only-show-errors "$out" "$bucket/backups/$root/$ts.tfstate"
  echo "  copied to $bucket/backups/$root/$ts.tfstate"
  s3 ls "$bucket/backups/$root/" | awk '{print $4}' | grep '\.tfstate$' | sort -r |
    tail -n "+$((keep + 1))" | while IFS= read -r old; do
      s3 rm --only-show-errors "$bucket/backups/$root/$old"
    done
done
