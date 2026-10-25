#!/usr/bin/bash
# Runs once at image build time, from the recipe's `script` module.
# Not copied into the image.
set -euo pipefail

# Fail the build instead of shipping an update check that can't work.
for tool in rpm-ostree jq crane slsa-verifier git ssh-keygen skopeo gpg flock; do
  command -v "$tool" >/dev/null || { echo "missing in base image: $tool" >&2; exit 1; }
done

chmod 0755 /usr/libexec/secureblue/verify-provenance.sh /usr/bin/myblue-setup \
  /usr/bin/myblue-opencode /usr/bin/myblue-agent-check \
  /usr/libexec/myblue/luks-add-fido2-key.sh /usr/libexec/myblue/keyaudit.sh

# Unsigned images I pull with podman. `ujust audit-secureblue` warns
# about these scopes; that is expected. quay.io/ramalama/ramalama is
# RamaLama's Vulkan image, which it picks for this GPU; it isn't signed.
policy=/etc/containers/policy.json
jq '.transports.docker += {
      "docker.io/cloudron/base": [{"type": "insecureAcceptAnything"}],
      "docker.io/selenium/standalone-chromium": [{"type": "insecureAcceptAnything"}],
      "quay.io/ramalama/ramalama": [{"type": "insecureAcceptAnything"}]
    }' "$policy" > /tmp/policy.json
cat /tmp/policy.json > "$policy"
rm /tmp/policy.json
