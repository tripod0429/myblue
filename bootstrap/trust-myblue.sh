#!/usr/bin/bash
# One-time, on a machine still running stock secureblue: make it accept
# images signed with this repo's cosign key, so you can rebase onto them.
# Writes the same files the image's `signing` module ships, with the same
# names, so the image takes them over after the first boot.
#
# Usage, from a checkout of this repo:  run0 ./bootstrap/trust-myblue.sh
set -euo pipefail

readonly OWNER=tripod0429 # lowercase
readonly NAME=myblue      # recipe `name`

repo=$(cd "$(dirname "$0")/.." && pwd)
scope="ghcr.io/$OWNER/$NAME"
key="/etc/pki/containers/$NAME.pub"
policy=/etc/containers/policy.json

install -D -m 0644 "$repo/cosign.pub" "$key"

cat > "/etc/containers/registries.d/$OWNER-$NAME.yaml" <<EOF
docker:
  $scope:
    use-sigstore-attachments: true
EOF

cp -a "$policy" "$policy.bak"
tmp=$(mktemp "$policy.XXXXXX")
jq --arg scope "$scope" --arg key "$key" \
  '.transports.docker[$scope] = [{
     type: "sigstoreSigned",
     keyPath: $key,
     signedIdentity: {type: "matchRepository"}
   }]' "$policy.bak" > "$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$policy"

echo "Trusted $scope. Old policy saved as $policy.bak."
echo "Next: rpm-ostree rebase ostree-image-signed:docker://$scope:latest"
