#!/usr/bin/bash
# Runs at image build time, after the `signing` module. Next to the cosign
# signature that module requires, policy.json also requires this machine's
# approval: a signature verify-provenance.sh makes with the machine's own
# key once an image has passed its checks, stored locally (registries.d
# `lookaside`). bootstrap/trust-myblue.sh writes the same entries.
set -euo pipefail

# Same as in verify-provenance.sh.
readonly IMAGE=ghcr.io/tripod0429/myblue
readonly KEYRING=/etc/pki/containers/myblue-approval.gpg
readonly SIGNATURES=/var/lib/containers/sigstore

policy=/etc/containers/policy.json
if ! jq -e --arg i "$IMAGE" '.transports.docker[$i] | length == 1 and .[0].type == "sigstoreSigned"' \
     "$policy" > /dev/null; then
  echo "policy.json: expected the signing module's single entry for $IMAGE" >&2
  exit 1
fi
jq --arg i "$IMAGE" --arg k "$KEYRING" '.transports.docker[$i] += [{
     type: "signedBy",
     keyType: "GPGKeys",
     keyPath: $k,
     signedIdentity: {type: "matchRepository"}
   }]' "$policy" > /tmp/policy.json
cat /tmp/policy.json > "$policy"
rm /tmp/policy.json

# The signing module's registries.d file for the image: replace it with
# the same entry plus the local signature store. One namespace can't be
# split across two files.
mapfile -t files < <(grep -lF "${IMAGE%/*}" /etc/containers/registries.d/*.yaml)
if (( ${#files[@]} != 1 )) || ! grep -qF 'use-sigstore-attachments: true' "${files[0]}"; then
  echo "registries.d: expected one file from the signing module for $IMAGE, found: ${files[*]:-none}" >&2
  exit 1
fi
cat > "${files[0]}" <<EOT
docker:
  $IMAGE:
    use-sigstore-attachments: true
    lookaside: file://$SIGNATURES
EOT
echo "Requires this machine's approval for $IMAGE (${files[0]})"
