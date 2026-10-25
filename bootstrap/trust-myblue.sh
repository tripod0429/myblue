#!/usr/bin/bash
# One-time, on a machine still running stock secureblue: make it accept
# images signed with this repo's cosign key and approved by this machine,
# then rebase onto the image after the checks every update gets. Writes the
# same files the image's `signing` module and myblue-approval-policy.sh
# ship, with the same names, so the image takes them over after the first
# boot.
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
# This machine's approvals, as in verify-provenance.sh.
approval_key=/etc/pki/containers/$NAME-approval.gpg
signatures=/var/lib/containers/sigstore

install -D -m 0644 "$repo/cosign.pub" "$key"

registries="/etc/containers/registries.d/$OWNER-$NAME.yaml"
cat > "$registries" <<EOF
docker:
  $scope:
    use-sigstore-attachments: true
    lookaside: file://$signatures
EOF
# run0 applies secureblue's umask 027. Rootless podman reads every file in
# registries.d, and one it can't read makes all its pulls fail.
chmod 0644 "$registries"

cp -a "$policy" "$policy.bak"
tmp=$(mktemp "$policy.XXXXXX")
jq --arg scope "$scope" --arg key "$key" --arg approval "$approval_key" \
  '.transports.docker[$scope] = [{
     type: "sigstoreSigned",
     keyPath: $key,
     signedIdentity: {type: "matchRepository"}
   }, {
     type: "signedBy",
     keyType: "GPGKeys",
     keyPath: $approval,
     signedIdentity: {type: "matchRepository"}
   }]' "$policy.bak" > "$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$policy"

echo "Trusted $scope. Old policy saved as $policy.bak."

# Check the image `latest` points to now (provenance, and the commit signed
# by a key in this checkout's allowed_signers) and approve it, then rebase
# onto `latest`, which updates follow. rpm-ostree refuses anything else the
# tag might point to by then: it has no approval.
digest=$(crane digest "$scope:latest")
"$repo/files/system/usr/libexec/secureblue/verify-provenance.sh" --bootstrap \
  "$repo/files/system/usr/share/myblue/allowed_signers" "$digest"
rpm-ostree rebase "ostree-image-signed:docker://$scope:latest"
echo "Next: systemctl reboot"
