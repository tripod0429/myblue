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
# The source must also be the installed image's source commit or a
# descendant, so older signed workflows/configurations cannot be replayed.
set -euo pipefail

# Trust anchors: hardcoded on purpose, never derived from the image being
# checked. GitHub user in lowercase; repo name = recipe `name`.
readonly IMAGE=ghcr.io/tripod0429/myblue
readonly SOURCE=github.com/tripod0429/myblue
readonly BRANCH=main
readonly ALLOWED_SIGNERS=/usr/share/myblue/allowed_signers
readonly SOURCE_COMMIT_FILE=/usr/share/myblue/source-commit

# Not set when run from a system service; slsa-verifier caches under it.
export HOME="${HOME:-/root}"

if [[ ! -x /usr/bin/rpm-ostree ]]; then
  echo "verify-provenance: only rpm-ostree systems are supported" >&2
  exit 1
fi

if ! installed_commit=$(cat "$SOURCE_COMMIT_FILE") ||
   [[ ! $installed_commit =~ ^[0-9a-f]{40}$ ]]; then
  echo "verify-provenance: missing or invalid installed source commit in $SOURCE_COMMIT_FILE" >&2
  exit 1
fi

ref=$(rpm-ostree status --booted --json | jq -r '.deployments[0]."container-image-reference"')
ref=${ref#*:docker://}

if [[ $ref != "$IMAGE:latest" ]]; then
  echo "verify-provenance: booted from '$ref', expected '$IMAGE:latest'" >&2
  exit 1
fi

digest=$(crane digest "$ref")
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
# Fetch ancestry, not just the tip: a shallow fetch cannot prove descent
# from the installed source. No branch tip or image-supplied label is trusted.
git -C "$work/repo.git" fetch -q --no-tags "https://$SOURCE" "$commit"
if ! git -C "$work/repo.git" \
    -c gpg.ssh.allowedSignersFile="$ALLOWED_SIGNERS" \
    -c gpg.openpgp.program=false \
    -c gpg.x509.program=false \
    verify-commit "$commit"; then
  echo "verify-provenance: $commit is not signed by a key in $ALLOWED_SIGNERS" >&2
  exit 1
fi

if ! git -C "$work/repo.git" merge-base --is-ancestor "$installed_commit" "$commit"; then
  echo "verify-provenance: $commit does not descend from installed source $installed_commit; refusing older or unrelated source history" >&2
  exit 1
fi
echo "verify-provenance: built from $commit, signed by an allowed key; source is unchanged or descends from $installed_commit"
