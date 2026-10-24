# myblue

My secureblue image, built with BlueBuild. It follows secureblue's own
supply-chain model:

1. **Commits** to `main` must be signed (GitHub ruleset).
2. **CI** restricts outbound runner traffic, tests RPM verification,
   checks the secureblue base image, then builds, signs with the
   cosign key and publishes SLSA provenance. Provenance is a statement
   signed by GitHub saying this image was built by this repo's workflow,
   from `main`.
3. **The machine** checks three things before every update:
   - rpm-ostree checks the cosign signature (`policy.json`).
   - `verify-provenance.sh` checks the provenance, then checks that the
     commit the image was built from is signed by a key in
     `/usr/share/myblue/allowed_signers` (the FIDO2 key on your token).
     secureblue runs this script before automatic updates and before
     `ujust update-system`.

GitHub vouches for the cosign signature (its key is a GitHub secret) and
for the provenance. The commit signature is the one thing someone with your
GitHub account, a `gh` token or a browser session can't produce: it needs
your token and a touch. GitHub's own signature on merges made in its web UI
doesn't count.

| File | Purpose |
|---|---|
| `recipes/recipe.yml` | What goes into the image |
| `files/system/` | Copied to `/`: Trivalent policies, `myblue-setup`, `verify-provenance.sh` and its `allowed_signers`, `luks-add-fido2-key.sh`, shell settings (`/etc/profile.d/myblue.sh`), the tmpfiles.d link to Mullvad's files |
| `files/justfiles/myblue.just` | Extra `ujust` commands: `add-luks-fido2-key` |
| `files/scripts/` | Run at build time, not shipped: Proton Mail Bridge and Mullvad installs, their RPM verifier, checks, `policy.json` additions |
| `files/scripts/upstream/` | Unmodified, commit-pinned secureblue package cleanup and checks |
| `files/keys/` | Proton's Bridge and Mullvad's code signing keys, for checking their RPMs at build time |
| `.github/workflows/build.yml` | Daily build plus an hourly check for a new secureblue base; base-image check, signing, provenance |
| `.github/dependabot.yml` | Weekly bumps for the pinned actions, in one PR |
| `tests/test_signed_rpms.py` | Offline regression tests for Bridge and Mullvad verification and installation ordering |
| `bootstrap/trust-myblue.sh` | One-time: lets stock secureblue accept your image |
| `keys/secureblue.pub` | secureblue's public key, for checking the base image (you add it) |
| `cosign.pub` | Your public signing key (you add it) |

## One-time setup

### 1. Fill in the blanks

- Your GitHub username, in lowercase, is set in:
  - `files/system/usr/libexec/secureblue/verify-provenance.sh`
  - `bootstrap/trust-myblue.sh`

  The build fails if the first one doesn't match the repo it builds from.
- The repo name must equal `name:` in the recipe (`myblue`). If you pick
  another name, change it in all three places.
- Copy your Trivalent policies into the image:
  ```sh
  cp ~/.config/mise/files/{web-apps,extensions}.json \
     files/system/etc/trivalent/policies/managed/
  ```
- Copy secureblue's public key from your running system, so the key that
  checks the base is one your machine already trusts. `policy.json` lists
  two secureblue keys; `secureblue-2025.pub` is the one that signs current
  images. Check it matches secureblue's `cosign.pub`:
  ```sh
  mkdir -p keys
  cp /usr/share/pki/containers/secureblue-2025.pub keys/secureblue.pub
  curl -fsSL https://raw.githubusercontent.com/secureblue/secureblue/live/cosign.pub |
    diff - keys/secureblue.pub && echo key ok
  ```

### 2. Signing key

Create it in RAM (`$XDG_RUNTIME_DIR` is a tmpfs), so the plain key never
reaches the disk, and keep only a copy encrypted to your GPG key:
```sh
cd "$(mktemp -d -p "$XDG_RUNTIME_DIR")"
cosign generate-key-pair   # press Enter for an empty password; CI can't use an encrypted key
gpg --encrypt --recipient <your GPG fingerprint> --output cosign.key.gpg cosign.key
gpg --decrypt cosign.key.gpg | cmp - cosign.key && echo backup ok
```
Copy `cosign.pub` into this repo and commit it. Move `cosign.key.gpg` to
an offline backup, never into git, then delete `cosign.key`. Step 4
uploads the key to GitHub straight from the backup.

### 3. GitHub account

- **Security keys:** register your YubiKeys as passkeys or security keys,
  remove TOTP and SMS, and keep the recovery codes offline.
- **Commit signing key:** add the SSH key on your token's FIDO2 side
  (`~/.ssh/tripod0429_signing.pub`) under *SSH and GPG keys* as a
  **signing key**. Commits in this repo use GitHub's noreply email, which
  GitHub always treats as verified; your dotfiles' git config switches to
  it based on the remote. Without the key, your commits show as unverified
  and the ruleset rejects your pushes.

### 4. The repository

Create it empty, as **public**, named `myblue`. Set the following before
the first push, so the first build already has its secret and
restrictions:

- **Rules → Rulesets → New branch ruleset** targeting the default branch.
  Enable *Require signed commits*, *Block force pushes* and *Restrict
  deletions*. Leave the bypass list empty.
- **Actions → General**:
  - *Allow select actions*: tick *Allow actions created by GitHub* and
    list:
    ```
    step-security/harden-runner@*,
    blue-build/*, sigstore/*, regclient/*, slsa-framework/*,
    hastd/free-disk-space@*, docker/setup-buildx-action@*,
    docker/setup-qemu-action@*, google-github-actions/auth@*
    ```
    The last four are used inside BlueBuild's action and the SLSA
    generator. If a run fails at *Set up job* with "not allowed", add the
    action it names.
    Existing repos must add `step-security/harden-runner@*` before pushing
    the runner-hardening changes.
  - Leave *Require actions to be pinned to a full-length commit SHA* **off**.
    The SLSA generator must be referenced by tag. Everything else in
    `build.yml` is already pinned by SHA.
  - *Workflow permissions*: read repository contents only. Untick *Allow
    GitHub Actions to create and approve pull requests*.
- **Environments → New environment** `release`:
  - *Deployment branches and tags*: selected branches, `main` only.
  - No required reviewers, so the daily build doesn't wait for you.
  - Add the secret from your backup:
    ```sh
    gpg --decrypt cosign.key.gpg | gh secret set SIGNING_SECRET --env release --repo <you>/myblue
    ```

Then push. Add the remote before the first commit: your git config picks
the commit identity from it.
```sh
git init -b main
git remote add origin https://github.com/<you>/myblue.git
git config user.email   # must print your noreply address
git add -A
git status              # no cosign.key in the list
git commit -m "Initial image"
git push -u origin main
```

### 5. First build

Push, then watch *Actions*. The first run creates the package
`ghcr.io/<you>/myblue`. Check it's **public** (your profile → *Packages*
→ `myblue` → *Package settings*); new packages can start out private.
The machine has to be able to read it without logging in.

Then check both signatures from your laptop
(`brew install cosign slsa-verifier crane`):
```sh
d=$(crane digest ghcr.io/<you>/myblue:latest)
cosign verify --key cosign.pub ghcr.io/<you>/myblue@$d > /dev/null && echo signature ok
slsa-verifier verify-image --source-uri github.com/<you>/myblue \
  --source-branch main ghcr.io/<you>/myblue@$d
```

### 6. Move your machine onto the image

1. **Remove mise's copies of the Trivalent policies.** Files you add to
   `/etc` count as local changes and would keep overriding the image's
   copies:
   ```sh
   run0 rm /etc/trivalent/policies/managed/{web-apps,extensions,javascript-jit}.json
   ```
   `javascript-jit.json` isn't in the image: JIT exceptions are kept by
   hand. Re-add them in Trivalent (*Settings → Privacy and security → Site
   settings → JavaScript optimization*); `myblue-setup` prints the list.
2. **Trust your key, rebase and reboot:**
   ```sh
   run0 ./bootstrap/trust-myblue.sh
   rpm-ostree rebase ostree-image-signed:docker://ghcr.io/<you>/myblue:latest
   systemctl reboot
   ```
3. **Hand `policy.json` back to the image**, so future policy changes from
   the image take effect. This drops any other local edits to it; check
   `diff <(jq -S . /usr/etc/containers/policy.json) <(jq -S . /etc/containers/policy.json)`
   first. The image already has your key and the podman entries for
   `docker.io` and `quay.io/ramalama`, so anything the diff shows is
   either a newer secureblue change (keep the image's version) or a local
   edit you need to carry into the recipe. RamaLama needs this step: until
   then, podman refuses its image.
   ```sh
   run0 cp /usr/etc/containers/policy.json /etc/containers/policy.json
   ```
4. **Remove leftover layering.** `rpm-ostree status` lists packages you
   had layered that are now in the image as inactive requests. Remove
   them with `rpm-ostree uninstall <pkgs>`. That includes `mullvad-vpn`;
   your Mullvad login and settings stay. The Mullvad repo that
   `ujust install-vpn` turned on is no longer needed:
   `run0 sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/mullvad.repo`.
5. **Test the update check:** `/usr/libexec/secureblue/verify-provenance.sh`
   should exit 0, print a `PASSED` line from slsa-verifier, a `Good "git"
   signature` line for your key, and `built from <commit>, signed by an
   allowed key`.

On a fresh machine, install stock secureblue first, then start at step 2.
That way secureblue's first-boot cleanup has already run.

## Proton Mail Bridge

Proton has no dnf repo for Bridge, only a signed RPM.
`files/scripts/install-proton-bridge.sh` reads Proton's version feed,
downloads the current RPM, requires a valid signature from the key in
`files/keys/` (fingerprint `D51E 64D3 E63E DC3E EF78 64CE E2C7 5D68
E623 4B07`), and installs it. Each daily build picks up the latest Bridge.

Verification uses a temporary RPM database containing only that key and
explicitly selects RPM's `rpmdb` keyring backend. Other keys already trusted
by the system cannot authenticate the download. Both digests and a signature
must verify, and the package must identify as `protonmail-bridge` for `x86_64`.
Only then is the key imported into the image's RPM database for DNF's own
signature recheck. Neither package install enables weak dependencies.

Autostart is Bridge's own *Open on startup* setting, not a service you
write: it adds an XDG autostart entry (`protonmail-bridge --no-window`),
which COSMIC runs as a systemd user unit and lists under *Startup
Applications*. Don't add Bridge there by hand: that copy starts without
`--no-window`. Turn off Bridge's *Automatic updates*: its launcher would
otherwise run newer versions it downloads into your home folder instead
of the image's. `myblue-setup` lists both settings, and Peergos's
equivalent, *Start on boot*.

## Mullvad VPN

The image has Mullvad's daemon and CLI, not its GUI.
`files/scripts/install-mullvad.sh` follows Mullvad's link to the current
stable RPM (`mullvad.net/en/download/app/rpm/latest`, which redirects to
`cdn.mullvad.net`). It checks the RPM with Bridge's verifier against
`files/keys/mullvad.asc`, Mullvad's code signing key (fingerprint `A119
8702 FC3E 0A09 A9AE 5B75 D5A1 D4F2 66DE 8DDF`), and installs it. Each daily
build picks up the latest version. Mullvad's dnf repo isn't used because
DNF would accept a package from it signed by any key the system trusts.
Its GitHub releases aren't used either: the latest one there is often the
Android app.

The package puts everything but the binaries in `/opt/Mullvad VPN`. On
these images `/opt` links to `/var/opt`, which image updates leave alone,
so the script installs it into `/usr/lib/opt/Mullvad VPN`, as rpm-ostree
does when layering. `/usr/lib/tmpfiles.d/myblue-mullvad.conf` links
`/opt/Mullvad VPN` there at boot. The script then deletes the Electron GUI
(about 350 MB), its launcher and its icons, keeping `resources/`, which the
daemon reads. It enables `mullvad-daemon` and `mullvad-early-boot-blocking`.
- **Login:** `mullvad account login`, then `mullvad auto-connect set on`
  and `mullvad connect`. `myblue-setup` prints these.
- **DNS:** a VPN's DNS doesn't work with Unbound, secureblue's other
  resolver. `myblue-setup` offers to switch to systemd-resolved, as
  `ujust install-vpn` did.
- **Split tunnelling** (`mullvad-exclude`) doesn't work: secureblue's
  cleanup removes its setuid bit, as for every setuid binary in the image.

secureblue removed `ujust install-vpn` for Fedora 45 (secureblue#2731),
along with Mullvad's repo file.

## RamaLama

`ramalama` comes from Fedora's repos. It runs models in rootless podman
containers, using an image from `quay.io/ramalama` that matches its minor
version. Those images aren't signed (no cosign signatures or attachments),
and secureblue's `policy.json` rejects anything it doesn't list, so
`myblue-image-setup.sh` allows `quay.io/ramalama/ramalama`. That is the
Vulkan image RamaLama picks for AMD GPUs (both the laptop's and the
desktop's), and the scope allows only it. If RamaLama starts picking another
image (ROCm, say), the pull fails with a policy error. Add that repo on
purpose, not the whole namespace. ROCm would also need `/dev/kfd`, which the
dotfiles' quadlet drop-in leaves out.

The model service that starts at login is a quadlet in the dotfiles. It
has no outbound network and only the GPU's `/dev/dri`.
Its chat UI (llama.cpp's `llama-ui`, a full PWA) is a Trivalent web app
in `web-apps.json` at `http://127.0.0.1:8080/`. That port has to match
`ramalama.port` in the dotfiles' `packages.yaml`.

## Shell settings

`ujust toggle-bash-environment-lockdown` resets `~/.bashrc`,
`~/.bash_profile`, `~/.bashrc.d` and `~/.config/environment.d` to
`/etc/skel`'s versions (or empty) and makes them immutable. Backups go to
`~/bash_env_files`. Turning it off only lifts the immutability, so anything
in those files is lost each time it's turned on. So the settings you'd put
there (gpg-agent as SSH agent, ghcup on `PATH`, the claude and opencode
aliases) are in `files/system/etc/profile.d/myblue.sh`, the same place
secureblue ships its own (`gnome-disable-jit.sh`,
`xx-bash-prompt-command.sh`). Being in the image, they're root-owned and
signed like the rest of it. The dotfiles leave `~/.bashrc` and
`~/.bash_profile` to secureblue.

The `claude` and `opencode` aliases start them inside nono, with the
`claude-haskell` and `opencode-haskell` profiles from the dotfiles. Both
agents can write their own config, and hooks in it would run
with your full access in a session started without nono. `command claude`
skips the alias.

- `--rollback` snapshots the launch folder. When a session changed files,
  nono offers to restore them on exit; later, `nono rollback list` and
  `nono rollback restore <id>`. The profiles keep the agents' own folders
  and caches out of the snapshots.
- `--strict-broker-path` refuses to start if the agent could write to a
  directory on `PATH`, where it could plant a program you'd later run
  outside the sandbox.
- The profiles block local Unix sockets (`af_unix_mediation`). Without
  that, an agent can ask systemd over D-Bus to run commands outside the
  sandbox (CVE-2026-47128; nono's fix is opt-in). Agents can't send desktop
  notifications or paste images from the clipboard as a result.
- opencode 2 always talks to a local server. `/usr/bin/myblue-opencode`
  starts a private one inside the sandbox on a port the profile allows
  (4097–4106) and stops it on exit, as `--standalone` does on a random port.
  Log in to ChatGPT with `/connect` in the TUI or `opencode auth login`.
  `opencode debug`, `mcp` and `plugin` need the background server, which
  the sandbox can't reach. Don't run opencode outside nono: that starts the
  unsandboxed background server (`opencode service stop` stops it).
- `myblue-agent-check` runs first. Either sandbox can edit the agents'
  instructions, skills and agent definitions (`~/.claude`,
  `~/.config/opencode`), and every later session of both agents loads
  them. It compares them with the dotfiles (`chezmoi status` and
  `chezmoi unmanaged`) and asks before starting the agent if a file
  changed or a new one appeared.

Don't put anything there that evaluates user-writable config at shell
start (`mise activate`, `direnv hook` and the like): malware running as you
could use it to set `LD_PRELOAD`, which is what the lockdown is meant to
stop.

## Build-time hardening

Both the hourly check and the build start with the same SHA-pinned
Harden-Runner action as secureblue, with `egress-policy: block`. The check
has a small allowlist for GitHub, GHCR and Sigstore; the build follows
secureblue's endpoint allowlist with GitHub's API and Proton added. A new
dependency or changed mirror may require an allowlist update. Investigate
the blocked endpoint rather than switching to audit mode or allowing all
outbound traffic. The SLSA generator remains upstream's reusable workflow.

Unlike secureblue, both steps set `disable-telemetry: true`, so the runner's
network and process data isn't sent to StepSecurity. There's no StepSecurity
insights page for a run; a blocked endpoint shows up as the step that failed
to connect. Telemetry can only be disabled in block mode.

After custom package installation, the recipe reapplies secureblue's PDF
thumbnailer removal, single-kernel check, SUID/SGID cleanup, sudo removal,
prohibited-package check and SELinux-context check, then clears DNF's
transaction history as upstream does. The vendored scripts
and their source commit are recorded in `files/scripts/upstream/README.md`.
The base image's metadata, initramfs and original audit baseline are retained.

Run the offline verification regression tests locally with:

```sh
python3 -m unittest discover -s tests -v
```

They run in the CI check job before a build can start. They cover isolated
keyring selection, wrong/extra keys, unsigned or invalid signatures, another
system-trusted signer, package identity, URL validation and install ordering.
They use mock package managers and do not install packages or change the
system keyring; actual RPM signature verification also needs testing with
real signed, unsigned and tampered packages.

## Day to day

- **Change the config:** make a signed commit (your `.gitconfig` signs by
  default) and push. The image builds and arrives with the next automatic
  update, then a reboot. Your touch approves whatever is staged, so check
  `git diff --staged` first.
- **Dependabot PRs:** they arrive as one PR a week with all action bumps.
  Don't merge it in the web UI. GitHub would sign that merge, and your
  machine refuses images built from it. Review and merge locally instead;
  GitHub then marks the PR as merged:
  ```sh
  git fetch origin pull/<N>/head
  git log -p HEAD..FETCH_HEAD          # what changed
  git merge --no-ff -m "Merge Dependabot PR #<N>" FETCH_HEAD   # touch the key
  git push
  ```
- **Pulling:** this clone has `merge.verifySignatures` on, so `git pull`
  refuses when the newest commit on GitHub isn't signed by a key in
  `allowed_signers`. Otherwise you could sign on top of someone else's
  commit without noticing. If a pull is refused, find out where the commit
  came from before doing anything else. If it's your own web-UI merge,
  review it, then approve it with a signed commit on top:
  ```sh
  git pull --no-verify-signatures
  git commit --allow-empty -m "Approve <commit>"   # touch the key
  git push
  ```
- **Working from another clone:** turn the same check on there:
  ```sh
  git config merge.verifySignatures true
  git config gpg.ssh.allowedSignersFile "$PWD/files/system/usr/share/myblue/allowed_signers"
  ```
- **The build fails at "Check commit signature":** the newest commit on
  `main` isn't signed by a key in `allowed_signers`, for example after a
  web-UI merge. Your machine would refuse that image anyway; this just
  makes it visible straight away. Fix it as under *Pulling*.
- **Another signing key (for example a backup token):** create a resident
  key on it (`ssh-keygen -t ed25519-sk -O resident`) and add its `.pub` as
  a line in `files/system/usr/share/myblue/allowed_signers`. Commit that
  with your current key and push. Add it on GitHub as a signing key too.
  The new key only counts once your machine has installed that image.
- **The build fails at "Verify secureblue base image":** secureblue's
  image failed its signature or provenance check, or secureblue rotated
  its key. Nothing gets built or published, so your machine stays on its
  current image. Only update `keys/secureblue.pub` once you've confirmed
  the rotation through secureblue's official channels.
- **The build fails in `install-proton-bridge.sh`:** either the download
  failed its signature check, or Proton changed its feed or rotated its
  key. Nothing is published. Only replace `files/keys/proton-bridge.asc`
  once Proton has announced the new key on its official site.
- **When images are built:** on every push to `main` (except README
  changes), daily at 09:17 UTC, and within the hour whenever secureblue
  publishes a new base (urgent fixes included). The hourly runs that find
  nothing new show the build as skipped. The machine still installs once a
  day (04:00) or at boot; for an urgent fix, run `ujust update-system` once
  the build is done, then reboot.
- **Another FIDO2 key for disk unlock:** `ujust setup-luks-fido2-unlock`
  wipes every enrolled FIDO2 key before enrolling, so use it only for the
  first key. For each extra key, plug in only that key and run
  `ujust add-luks-fido2-key`. It asks for the disk passphrase or recovery
  key, then the key's current PIN; the PIN isn't changed and nothing on the
  key is touched. Reboot with each key on its own to check it unlocks.
- **Updates stop arriving:** `journalctl -u rpm-ostreed-automatic` shows
  why. secureblue also warns you once the system is a week out of date.
  `is not signed by a key in /usr/share/myblue/allowed_signers` means the
  newest image was built from a commit you didn't sign; see *Pulling*.
- **Following secureblue's BlueBuild versions:** Dependabot can't bump the
  BlueBuild CLI (`cli_version` in `build.yml`) or the modules image digest
  (`source:` on each module in the recipe). When secureblue bumps them, in
  `.github/workflows/build-one-recipe.yml` and
  `recipes/common/common-modules.yml` on their `live` branch, copy the new
  values.
- **Following secureblue's package hardening:** compare
  `recipes/common/final-modules.yml` and the scripts listed in
  `files/scripts/upstream/README.md` with upstream, then update the vendored
  scripts from a reviewed commit. Also follow their Harden-Runner pin and
  build endpoint allowlist. Dependabot handles the action version, not the
  endpoint list or vendored scripts.
- **`ujust audit-secureblue`** reports `policy.json` as modified (INFO) and
  warns about the two `docker.io` scopes and `quay.io/ramalama/ramalama`.
  That's expected. Don't copy your
  policy over `/usr/share/secureblue/etc/containers/policy.json` to silence
  it: the audit would then stop checking the policy at all.

## Limits

- The FIDO2 key on your token is the root of trust for what gets
  installed. Someone who controls your GitHub account can still stop
  updates (break the build, delete the package), and can read the cosign
  key through a workflow on `main`, but can't get an image past the update
  check.
- Only the commit an image was built from is checked. Earlier commits are
  trusted because you signed on top of them, which is why `git pull`
  refuses commits you didn't sign.
- If you lose every key in `allowed_signers`, updates stop. To recover:
  1. Add a new key to the file and to GitHub as a signing key.
  2. Commit the change, signed with the new key, and push.
  3. Once it's built, run `rpm-ostree upgrade` by hand on each machine.
     That checks only the cosign signature.

  A backup signing key in the file avoids this.
- This is a single-maintainer repo: signed commits do not replace
  secureblue's independent maintainer review. Require independent source
  review if another trusted reviewer becomes available; do not put a manual
  approval gate on every scheduled build.
- The provenance and commit checks run on the two normal update paths.
  Typing `rpm-ostree upgrade` by hand skips them, and then only the cosign
  signature is checked.
- The checks look at the digest `latest` points to, and the image is
  fetched a moment later. secureblue's updater has the same small window.
- Once `policy.json` can match GitHub workflow identities (upstream work
  in progress), rpm-ostree could enforce the provenance check itself.
