#!/usr/bin/bash
# One-time, on a machine still running stock secureblue: make it accept
# images signed with this repo's cosign key, then rebase onto the image
# after the checks every update gets. Writes the same files the image's
# `signing` module ships, with the same names, so the image takes them
# over after the first boot.
#
# Usage, from a checkout of this repo whose commit you verified with your
# own key (README, step 6):  run0 ./bootstrap/trust-myblue.sh
set -euo pipefail

readonly OWNER=tripod0429 # lowercase
readonly NAME=myblue      # recipe `name`

repo=$(cd "$(dirname "$0")/.." && pwd)
scope="ghcr.io/$OWNER/$NAME"
key="/etc/pki/containers/$NAME.pub"
policy=/etc/containers/policy.json

install -D -m 0644 "$repo/cosign.pub" "$key"

registries="/etc/containers/registries.d/$OWNER-$NAME.yaml"
cat > "$registries" <<EOF
docker:
  $scope:
    use-sigstore-attachments: true
EOF
# run0 applies secureblue's umask 027. Rootless podman reads every file in
# registries.d, and one it can't read makes all its pulls fail.
chmod 0644 "$registries"

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

# Check the image `latest` points to now (provenance, and the commit signed
# by a key in this checkout's allowed_signers), then rebase onto `latest`,
# which updates follow. Like every update, the rebase looks the tag up
# again a moment after the check (README, Limits).
digest=$(crane digest "$scope:latest")
"$repo/files/system/usr/libexec/secureblue/verify-provenance.sh" --bootstrap \
  "$repo/files/system/usr/share/myblue/allowed_signers" "$digest"
rpm-ostree rebase "ostree-image-signed:docker://$scope:latest"
echo "Next: systemctl reboot"
