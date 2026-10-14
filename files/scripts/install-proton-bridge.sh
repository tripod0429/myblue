#!/usr/bin/bash
# Runs at image build time, from the recipe's `script` module.
# Installs the latest Proton Mail Bridge from Proton's signed RPM. Proton
# has no dnf repo for Bridge; its version feed names the current RPM.
set -euo pipefail

feed=https://proton.me/download/current_version_linux.json
# Proton's Bridge signing key, vendored in this repo (not shipped in the
# image). Fingerprint D51E 64D3 E63E DC3E EF78 64CE E2C7 5D68 E623 4B07.
key="${CONFIG_DIRECTORY:-/tmp/files}/keys/proton-bridge.asc"

url=$(curl -fsSL --retry 3 "$feed" | jq -er '.RpmFile')
case "$url" in
  https://proton.me/download/bridge/protonmail-bridge-*.x86_64.rpm) ;;
  *) echo "unexpected Bridge download URL: $url" >&2; exit 1 ;;
esac

rpm_file="/tmp/${url##*/}"
curl -fsSL --retry 3 -o "$rpm_file" "$url"

# Require a valid signature from that key. An unsigned package would only
# print "digests OK", so check for the full line.
rpm --import "$key"
check=$(rpm --checksig "$rpm_file" || true)
echo "$check"
if [[ $check != "$rpm_file: digests signatures OK" ]]; then
  echo "Bridge RPM signature check failed" >&2
  exit 1
fi

dnf -y install --setopt=localpkg_gpgcheck=1 "$rpm_file"
rm -f "$rpm_file"
