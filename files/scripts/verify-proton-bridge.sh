#!/usr/bin/bash
# Build-time only. Usage: bash verify-proton-bridge.sh PACKAGE.rpm KEY.asc
# Do not consult the system RPM keyring, even if it trusts other signers.
set -euo pipefail

if [[ $# != 2 ]]; then
  echo "Usage: $0 PACKAGE.rpm KEY.asc" >&2
  exit 2
fi

readonly FINGERPRINT=D51E64D3E63EDC3EEF7864CEE2C75D68E6234B07
rpm_file=$1
key=$2

workdir=$(mktemp -d)
trap 'rm -rf -- "$workdir"' EXIT
# Force the rpmdb backend: a future fs-keyring default must not use the
# system's certificates just because --dbpath names a temporary database.
rpm_args=(--define '_keyring rpmdb' --dbpath "$workdir/rpmdb")
rpmkeys "${rpm_args[@]}" --import "$key"
fingerprints=$(LC_ALL=C rpmkeys "${rpm_args[@]}" --list | awk '{print toupper($1)}')
if [[ $fingerprints != "$FINGERPRINT" ]]; then
  echo "Bridge signing key fingerprint mismatch: $fingerprints" >&2
  exit 1
fi

if ! check=$(LC_ALL=C rpmkeys "${rpm_args[@]}" --checksig "$rpm_file" 2>&1); then
  printf '%s\n' "$check" >&2
  exit 1
fi
printf '%s\n' "$check"
# Exit status alone does not suffice: an unsigned RPM can report only
# "digests OK". Require both digests and a signature from the pinned key.
if [[ $check != "$rpm_file: digests signatures OK" ]]; then
  echo "Bridge RPM signature check failed" >&2
  exit 1
fi

identity=$(LC_ALL=C rpm "${rpm_args[@]}" -qp --qf '%{NAME} %{ARCH}' "$rpm_file")
if [[ $identity != 'protonmail-bridge x86_64' ]]; then
  echo "Unexpected Bridge package identity: $identity" >&2
  exit 1
fi
