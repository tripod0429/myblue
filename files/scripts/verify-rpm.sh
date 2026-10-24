#!/usr/bin/bash
# Build-time only. Usage: bash verify-rpm.sh PACKAGE.rpm KEY.asc FINGERPRINT NAME
# Requires PACKAGE.rpm to be NAME for x86_64, signed by KEY.asc, which must
# hold exactly one key, FINGERPRINT.
# Do not consult the system RPM keyring, even if it trusts other signers.
set -euo pipefail

if [[ $# != 4 ]]; then
  echo "Usage: $0 PACKAGE.rpm KEY.asc FINGERPRINT NAME" >&2
  exit 2
fi

rpm_file=$1
key=$2
fingerprint=$3
name=$4

workdir=$(mktemp -d)
trap 'rm -rf -- "$workdir"' EXIT
# Force the rpmdb backend: a future fs-keyring default must not use the
# system's certificates just because --dbpath names a temporary database.
rpm_args=(--define '_keyring rpmdb' --dbpath "$workdir/rpmdb")
rpmkeys "${rpm_args[@]}" --import "$key"
fingerprints=$(LC_ALL=C rpmkeys "${rpm_args[@]}" --list | awk '{print toupper($1)}')
if [[ $fingerprints != "$fingerprint" ]]; then
  echo "$name signing key fingerprint mismatch: $fingerprints" >&2
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
  echo "$name RPM signature check failed" >&2
  exit 1
fi

identity=$(LC_ALL=C rpm "${rpm_args[@]}" -qp --qf '%{NAME} %{ARCH}' "$rpm_file")
if [[ $identity != "$name x86_64" ]]; then
  echo "Unexpected $name package identity: $identity" >&2
  exit 1
fi
