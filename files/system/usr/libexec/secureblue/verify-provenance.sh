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
# On normal updates, the source must also be the installed image's source
# commit or a descendant, so older signed workflows cannot be replayed.
#
# Then it approves exactly that image for this machine: a signature with
# this machine's own key, which policy.json requires next to the cosign
# signature. rpm-ostree refuses any image without one, so a tag moved after
# the check, or a plain `rpm-ostree upgrade`, can't bring in an image this
# script didn't check.
#
#   verify-provenance.sh                              before an update
#   verify-provenance.sh --bootstrap SIGNERS DIGEST   first install, from
#       bootstrap/trust-myblue.sh, or recovery: checks DIGEST against the
#       SIGNERS file you give it, without requiring a myblue boot or an
#       installed source-history floor (an explicit root recovery operation)
set -euo pipefail

# Trust anchors: hardcoded on purpose, never derived from the image being
# checked. GitHub user in lowercase; repo name = recipe `name`.
readonly IMAGE=ghcr.io/tripod0429/myblue
readonly SOURCE=github.com/tripod0429/myblue
readonly BRANCH=main
readonly SOURCE_COMMIT_FILE=/usr/share/myblue/source-commit
ALLOWED_SIGNERS=/usr/share/myblue/allowed_signers

# This machine's approvals. The policy.json and registries.d entries that
# require them come from files/scripts/myblue-approval-policy.sh (and
# bootstrap/trust-myblue.sh, which writes the same).
readonly CONTAINERS=/etc/containers
readonly KEYRING=/etc/pki/containers/myblue-approval.gpg
readonly SIGNATURES=/var/lib/containers/sigstore
readonly GNUPG=/var/lib/myblue/approval-gnupg

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

# Approving needs root. `ujust update-system` runs this as you, so hand
# over to a service that runs it as root; a polkit rule lets you start it.
# The service is Type=oneshot, so `start` waits for it and fails if it
# does. (`--wait` would also ask polkit to keep a reference to the unit,
# which the rule doesn't allow: a password prompt that times out.)
if (( EUID != 0 )); then
  if (( bootstrap )); then
    echo "verify-provenance: --bootstrap must run as root" >&2
    exit 1
  fi
  if systemctl start myblue-approve.service; then
    journalctl -u myblue-approve.service -n 3 -o cat --no-pager 2>/dev/null || true
    exit 0
  fi
  echo "verify-provenance: the check failed; see journalctl -u myblue-approve.service" >&2
  exit 1
fi

# Not set when run from a system service; slsa-verifier caches under it.
export HOME="${HOME:-/root}"

if [[ ! -x /usr/bin/rpm-ostree ]]; then
  echo "verify-provenance: only rpm-ostree systems are supported" >&2
  exit 1
fi

# Only an explicit root bootstrap/recovery may operate without an installed
# source floor. Missing metadata must never disable it on normal updates.
if (( !bootstrap )); then
  if ! installed_commit=$(cat "$SOURCE_COMMIT_FILE") ||
     [[ ! $installed_commit =~ ^[0-9a-f]{40}$ ]]; then
    echo "verify-provenance: missing or invalid installed source commit in $SOURCE_COMMIT_FILE" >&2
    exit 1
  fi
fi

# Approvals only protect if this machine's policy asks for them. A copy of
# policy.json or registries.d edited before this was added doesn't.
if ! jq -e --arg i "$IMAGE" --arg k "$KEYRING" \
       '.transports.docker[$i] | any(.type == "signedBy" and .keyPath == $k)' \
       "$CONTAINERS/policy.json" > /dev/null ||
   ! grep -qsxF "    lookaside: file://$SIGNATURES" "$CONTAINERS"/registries.d/*.yaml; then
  echo "verify-provenance: $CONTAINERS doesn't require this machine's approval for $IMAGE." >&2
  echo "Copy policy.json and registries.d/ from /usr/etc/containers (README, step 6)." >&2
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
trap 'rm -rf "$work"; GNUPGHOME=$GNUPG gpgconf --kill gpg-agent 2> /dev/null || true' EXIT
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

# Do this before generating a machine key or writing ANY approval.
if (( !bootstrap )); then
  if ! git -C "$work/repo.git" merge-base --is-ancestor "$installed_commit" "$commit"; then
    echo "verify-provenance: $commit does not descend from installed source $installed_commit; refusing older or unrelated source history" >&2
    exit 1
  fi
fi
echo "verify-provenance: built from $commit, signed by an allowed key"

# The machine's approval key: GPG, the only kind of key policy.json can
# check against signatures stored locally. Created on first use, kept by
# root; only the public half is in $KEYRING. If either half is missing,
# start over: earlier approvals don't matter, only this one does.
exec 9> /run/myblue-approval.lock
flock 9
if [[ ! -s $KEYRING ]] ||
   ! GNUPGHOME=$GNUPG gpg --batch --list-secret-keys --with-colons 2> /dev/null | grep -q '^sec'; then
  rm -rf "$GNUPG"
  install -d -m 0700 "$GNUPG"
  GNUPGHOME=$GNUPG gpg --batch --quiet --passphrase '' \
    --quick-gen-key "myblue approval for $(uname -n)" ed25519 sign never
  GNUPGHOME=$GNUPG gpg --batch --export > "$work/key.gpg"
  install -D -m 0644 "$work/key.gpg" "$KEYRING"
  echo "verify-provenance: created this machine's approval key"
fi
fpr=$(GNUPGHOME=$GNUPG gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr/ { print $10; exit }')

# approve DIGEST: sign the manifest stored under DIGEST. skopeo checks it
# against the digest; the signature names the digest too.
approve() {
  local manifest=$work/${1#sha256:}.json dir="$SIGNATURES/${IMAGE#*/}@${1/:/=}"
  skopeo inspect --raw "docker://$IMAGE@$1" > "$manifest"
  install -d -m 0755 "$dir"
  GNUPGHOME=$GNUPG skopeo standalone-sign "$manifest" "$IMAGE:latest" "$fpr" -o "$dir/signature-1.new"
  mv -f "$dir/signature-1.new" "$dir/signature-1"
}
# Both the index and the amd64 image in it (myblue is built for amd64 only):
# which of the two gets checked depends on how an image is fetched.
approve "$digest"
image=$(jq -r '.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest' \
  "$work/${digest#sha256:}.json")
[[ -n $image ]] && approve "$image"

# Only this image stays approved. An approval left for an older image would
# let a tag moved back to it bring it in again; the deployed images don't
# need one, since nothing fetches them again.
for dir in "$SIGNATURES/${IMAGE#*/}"@*; do
  [[ -d $dir ]] || continue
  case ${dir##*@} in
    "${digest/:/=}" | "${image/:/=}") ;;
    *) rm -rf "$dir" ;;
  esac
done
echo "verify-provenance: approved ${digest} for this machine"
