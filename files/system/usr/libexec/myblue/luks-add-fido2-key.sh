#!/usr/bin/bash
# Enrolls one more FIDO2 key for LUKS unlock, next to the ones
# `ujust setup-luks-fido2-unlock` set up. That command wipes every FIDO2
# slot before it enrolls, so it can't add a second key.
set -euo pipefail

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

ask() {
  local answer
  read -rp "$1 [y/N] " answer
  [[ $answer == [yY]* ]]
}

[[ $UID -eq 0 ]] || die "This script must be run as root."

# The root disk, found the same way as secureblue's luks-enable-fido2-unlock.sh.
uuid=$(xargs -n1 -a /proc/cmdline | sed -n 's/^rd\.luks\.uuid=luks-//p')
disk=/dev/disk/by-uuid/$uuid
[[ -n $uuid && -L $disk ]] ||
  die "No LUKS device from rd.luks.uuid=luks-<uuid> on the kernel command line."

dump=$(cryptsetup luksDump "$disk")
if ! grep -q systemd-fido2 <<<"$dump" || ! grep -q fido2-device=auto /etc/crypttab; then
  die "FIDO2 unlock isn't set up yet. Run 'ujust setup-luks-fido2-unlock' with your first key."
fi

# Columns: PATH MANUFACTURER PRODUCT COMPATIBLE RK CLIENTPIN UP UV ALWAYSUV.
# PRODUCT can contain spaces, so CLIENTPIN is counted from the end.
mapfile -t keys < <(systemd-cryptenroll --fido2-device=list 2>/dev/null | grep '^/dev/hidraw')
case ${#keys[@]} in
  0) die "No FIDO2 key found. Plug in the new key. If usbguard is on, allow it first:
  usbguard list-devices
  usbguard allow-device <number> -p" ;;
  1) ;;
  *) die "More than one FIDO2 key is plugged in. Unplug all but the new one." ;;
esac

# Without a PIN on the key, systemd would quietly enroll it as touch-only.
# ✓, or + when the locale isn't UTF-8.
pin=$(awk '{print $(NF-3)}' <<<"${keys[0]}")
[[ $pin == ✓ || $pin == + ]] ||
  die "This key has no FIDO2 PIN. Set one with the key's own tool first; this script doesn't set or change PINs."

cat <<'EOF'
This adds the plugged-in key as another way to unlock the disk. You'll be
asked for the disk passphrase or recovery key, then the key's current PIN
and a touch. The PIN isn't changed.

Nothing is stored on the key: the disk's LUKS header keeps a credential ID
that only this key can turn into the unlock secret. Passkeys, SSH keys and
anything else on the key stay as they are.

crypttab, the initramfs and the recovery key aren't touched, and keys
already enrolled keep working. 'ujust remove-luks-fido2-unlock' removes
all FIDO2 keys at once.

EOF
ask "Enroll this key?" || exit 1

systemd-cryptenroll --fido2-device=auto "$disk"

printf '\nKey slots on %s:\n' "$disk"
systemd-cryptenroll "$disk"
printf '\nReboot once with each key plugged in on its own to check it unlocks the disk.\n'
