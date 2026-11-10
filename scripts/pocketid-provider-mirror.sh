#!/usr/bin/env bash
# Installs the Pocket ID provider from its official releases
# (github.com/pocket-id/terraform-provider) into a local filesystem mirror.
#
# The provider is still published in the Registry as trozz/pocketid, but the
# Registry points its downloads at the original github.com/Trozz repository,
# whose releases are gone since the project moved to the pocket-id org, so a
# plain `terraform init` fails with 404. The binaries are the same: the
# committed .terraform.lock.hcl hashes match the official SHA256SUMS, and
# Terraform refuses any zip from the mirror that doesn't match them.
#
# Usage: eval "$(scripts/pocketid-provider-mirror.sh [mirror-dir] [os_arch ...])"
#   stdout is only the export of TF_CLI_CONFIG_FILE; progress goes to stderr.
# Defaults: mirror-dir .terraform-mirror (git-ignored), os_arch of this host.
set -euo pipefail

cd "$(dirname "$0")/.."
mirror=$(mkdir -p "${1:-.terraform-mirror}" && cd "${1:-.terraform-mirror}" && pwd)
shift || true

version=$(sed -n 's/^ *version *= *"\([0-9][^"]*\)".*/\1/p' terraform/identity/versions.tf | head -1)
[ -n "$version" ] || { echo "no pocketid version in terraform/identity/versions.tf" >&2; exit 1; }

if [ $# -eq 0 ]; then
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
  set -- "${os}_${arch}"
fi

dir="$mirror/registry.terraform.io/trozz/pocketid"
mkdir -p "$dir"
for platform in "$@"; do
  zip="terraform-provider-pocketid_${version}_${platform}.zip"
  [ -f "$dir/$zip" ] && continue
  curl -fsSL -o "$dir/$zip.tmp" \
    "https://github.com/pocket-id/terraform-provider/releases/download/v${version}/${zip}"
  mv "$dir/$zip.tmp" "$dir/$zip"
  echo "pocketid ${version} ${platform} -> $dir/$zip" >&2
done

cat >"$mirror/terraform.rc" <<EOF
provider_installation {
  filesystem_mirror {
    path    = "$mirror"
    include = ["registry.terraform.io/trozz/pocketid"]
  }
  direct {
    exclude = ["registry.terraform.io/trozz/pocketid"]
  }
}
EOF
echo "export TF_CLI_CONFIG_FILE=$mirror/terraform.rc"
