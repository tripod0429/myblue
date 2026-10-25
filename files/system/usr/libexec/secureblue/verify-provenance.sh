#!/usr/bin/bash
# Replaces secureblue's script of the same name, which only accepts
# ghcr.io/secureblue images. secureblue runs this before automatic updates
# (rpm-ostreed-automatic.service) and before `ujust update-system`; a
# non-zero exit blocks the update.
#
# It checks that the image `latest` points to was built by this repo's
# GitHub workflow from the main branch, using the SLSA provenance the
# build publishes next to the image, and that the commit it was built
# from is signed by a key in ALLOWED_SIGNERS. GitHub vouches for the
# provenance, so the signature is what someone who controls the GitHub
# account can't produce.
#
#   verify-provenance.sh                              before an update
#   verify-provenance.sh --bootstrap SIGNERS DIGEST   first install, from
#       bootstrap/trust-myblue.sh: checks DIGEST against the SIGNERS file of
#       a checkout you verified, without requiring a myblue boot
set -euo pipefail

# Trust anchors: hardcoded on purpose, never derived from the image being
# checked. GitHub user in lowercase; repo name = recipe `name`.
readonly IMAGE=ghcr.io/tripod0429/myblue
readonly SOURCE=github.com/tripod0429/myblue
readonly BRANCH=main
ALLOWED_SIGNERS=/usr/share/myblue/allowed_signers

usage() { echo "usage: $0 [--bootstrap ALLOWED_SIGNERS DIGEST]" >&2; exit 2; }
bootstrap=0
case $# in
  0) ;;
  3) [[ $1 == --bootstrap ]] || usage
     bootstrap=1 ALLOWED_SIGNERS=$2 digest=$3 ;;
  *) usage ;;
esac
if [[ ! -r $ALLOWED_SIGNERS ]]; then
  echo "verify-provenance: can't read $ALLOWED_SIGNERS" >&2
  exit 1
fi

# Not set when run from a system service; slsa-verifier caches under it.
export HOME="${HOME:-/root}"

if [[ ! -x /usr/bin/rpm-ostree ]]; then
  echo "verify-provenance: only rpm-ostree systems are supported" >&2
  exit 1
fi

if (( !bootstrap )); then
  ref=$(rpm-ostree status --booted --json | jq -r '.deployments[0]."container-image-reference"')
  if [[ $ref != "ostree-image-signed:docker://$IMAGE:latest" ]]; then
    echo "verify-provenance: booted from '$ref', expected 'ostree-image-signed:docker://$IMAGE:latest'" >&2
    exit 1
  fi
  digest=$(crane digest "$IMAGE:latest")
fi
if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "verify-provenance: not a digest: '$digest'" >&2
  exit 1
fi
provenance=$(slsa-verifier verify-image \
  --source-uri "$SOURCE" \
  --source-branch "$BRANCH" \
  --print-provenance \
  "$IMAGE@$digest")

# SLSA v0.2 layout, as written by the generator version build.yml pins.
commit=$(jq -r '.predicate.invocation.configSource.digest.sha1' <<<"$provenance")
if [[ ! $commit =~ ^[0-9a-f]{40}$ ]]; then
  echo "verify-provenance: no source commit in the provenance" >&2
  exit 1
fi

# Fetching from GitHub is safe: git checks the commit against its hash,
# and the hash comes from the verified provenance. Ignore every git config
# on this machine, and disable the OpenPGP and X.509 verifiers, so only an
# SSH signature by a key in ALLOWED_SIGNERS passes. GitHub's own signature
# on merges made in its web UI is OpenPGP and doesn't count.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
git init -q --bare "$work/repo.git"
git -C "$work/repo.git" fetch -q --depth=1 "https://$SOURCE" "$commit"
if ! git -C "$work/repo.git" \
    -c gpg.ssh.allowedSignersFile="$ALLOWED_SIGNERS" \
    -c gpg.openpgp.program=false \
    -c gpg.x509.program=false \
    verify-commit "$commit"; then
  echo "verify-provenance: $commit is not signed by a key in $ALLOWED_SIGNERS" >&2
  exit 1
fi
echo "verify-provenance: built from $commit, signed by an allowed key"
