#!/usr/bin/bash
# Runs at image build time, from the recipe's `script` module.
# Installs the latest Mullvad VPN daemon and CLI from Mullvad's signed RPM,
# checked like Bridge's against only the key in files/keys/, then removes
# the GUI. Packages from Mullvad's dnf repo would pass with any key the
# system trusts. Mullvad's GitHub releases also hold Android ones; this link
# always names the current stable RPM.
set -euo pipefail

latest=https://mullvad.net/en/download/app/rpm/latest
# Mullvad's code signing key, vendored in this repo, and its fingerprint.
key="${CONFIG_DIRECTORY:-/tmp/files}/keys/mullvad.asc"
fingerprint=A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF
opt="/usr/lib/opt/Mullvad VPN"

url=$(curl --proto '=https' -fsS --retry 3 -o /dev/null -w '%{redirect_url}' "$latest")
case "$url" in
  https://cdn.mullvad.net/app/desktop/releases/*/MullvadVPN-*_x86_64.rpm) ;;
  *) echo "unexpected Mullvad download URL: $url" >&2; exit 1 ;;
esac

workdir=$(mktemp -d)
trap 'rm -rf -- "$workdir"' EXIT
rpm_file="$workdir/${url##*/}"
curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 -o "$rpm_file" "$url"

# Verify BEFORE importing into the system keyring or installing anything.
bash "${CONFIG_DIRECTORY:-/tmp/files}/scripts/verify-rpm.sh" \
  "$rpm_file" "$key" "$fingerprint" mullvad-vpn

# The package installs to /opt/Mullvad VPN. /opt links to /var/opt, which
# image updates leave alone, so install through a link to /usr/lib/opt, as
# rpm-ostree does for layered packages. At boot, tmpfiles.d recreates the
# link (files/system/usr/lib/tmpfiles.d/myblue-mullvad.conf).
mkdir -p "$opt" /var/opt
ln -s "$opt" "/var/opt/Mullvad VPN"
rpm --import "$key"
dnf -y install --setopt=localpkg_gpgcheck=1 --setopt=install_weak_deps=False "$rpm_file"
rm "/var/opt/Mullvad VPN"

# CLI only: remove the Electron GUI (everything but resources/, and
# resources/app.asar), its launcher and its icons. The daemon reads
# resources/ through MULLVAD_RESOURCE_DIR.
find "$opt" -mindepth 1 -maxdepth 1 ! -name resources -exec rm -rf -- {} +
rm -f -- "$opt/resources/app.asar" /usr/share/applications/mullvad-vpn.desktop \
  /usr/share/icons/hicolor/*/apps/mullvad-vpn.png

# The package's scripts enable both already; don't depend on that.
systemctl enable mullvad-daemon.service mullvad-early-boot-blocking.service
mullvad --version
mullvad-daemon --version
