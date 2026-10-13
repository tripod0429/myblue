#!/usr/bin/bash
# Replaces secureblue's script of the same name, which only accepts
# ghcr.io/secureblue images. secureblue runs this before automatic updates
# (rpm-ostreed-automatic.service) and before `ujust update-system`; a
# non-zero exit blocks the update.
#
# It checks that the image `latest` points to was built by this repo's
# GitHub workflow from the main branch, using the SLSA provenance the
# build publishes next to the image.
set -euo pipefail

# Trust anchors: hardcoded on purpose, never derived from the booted image.
# GitHub user in lowercase; repo name = recipe `name`.
readonly IMAGE=ghcr.io/tripod0429/myblue
readonly SOURCE=github.com/tripod0429/myblue
readonly BRANCH=main

# Not set when run from a system service; slsa-verifier caches under it.
export HOME="${HOME:-/root}"

if [[ ! -x /usr/bin/rpm-ostree ]]; then
  echo "verify-provenance: only rpm-ostree systems are supported" >&2
  exit 1
fi

ref=$(rpm-ostree status --booted --json | jq -r '.deployments[0]."container-image-reference"')
ref=${ref#*:docker://}

if [[ $ref != "$IMAGE:latest" ]]; then
  echo "verify-provenance: booted from '$ref', expected '$IMAGE:latest'" >&2
  exit 1
fi

digest=$(crane digest "$ref")
slsa-verifier verify-image \
  --source-uri "$SOURCE" \
  --source-branch "$BRANCH" \
  "$IMAGE@$digest"
