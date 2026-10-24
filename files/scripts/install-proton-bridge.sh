#!/usr/bin/bash
# Runs at image build time, from the recipe's `script` module.
# Installs the latest Proton Mail Bridge from Proton's signed RPM. Proton
# has no dnf repo for Bridge; its version feed names the current RPM.
set -euo pipefail

feed=https://proton.me/download/current_version_linux.json
# Proton's Bridge signing key, vendored in this repo, and its fingerprint.
key="${CONFIG_DIRECTORY:-/tmp/files}/keys/proton-bridge.asc"
fingerprint=D51E64D3E63EDC3EEF7864CEE2C75D68E6234B07

url=$(curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 "$feed" | jq -er '.RpmFile')
case "$url" in
  https://proton.me/download/bridge/protonmail-bridge-*.x86_64.rpm) ;;
  *) echo "unexpected Bridge download URL: $url" >&2; exit 1 ;;
esac

workdir=$(mktemp -d)
trap 'rm -rf -- "$workdir"' EXIT
rpm_file="$workdir/${url##*/}"
curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 -o "$rpm_file" "$url"

# Verify BEFORE importing into the system keyring or installing anything.
# Existing Fedora/COPR keys must not authenticate a Bridge download.
bash "${CONFIG_DIRECTORY:-/tmp/files}/scripts/verify-rpm.sh" \
  "$rpm_file" "$key" "$fingerprint" protonmail-bridge

# DNF still rechecks the verified local RPM. This import is deliberately
# after the isolated check; the public key remains in the image's RPM DB.
rpm --import "$key"
dnf -y install --setopt=localpkg_gpgcheck=1 --setopt=install_weak_deps=False "$rpm_file"
