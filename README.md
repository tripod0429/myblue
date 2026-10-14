# myblue

My secureblue image, built with BlueBuild. It follows secureblue's own
supply-chain model:

1. **Commits** to `main` must be signed (GitHub ruleset).
2. **CI** checks the secureblue base image, then builds, signs with the
   cosign key and publishes SLSA provenance. Provenance is a statement
   signed by GitHub saying this image was built by this repo's workflow,
   from `main`.
3. **The machine** checks two things before every update:
   - rpm-ostree checks the cosign signature (`policy.json`).
   - `verify-provenance.sh` checks the provenance. secureblue runs this
     script before automatic updates and before `ujust update-system`.

A stolen signing key on its own can't get an image past step 3. Getting
past it would take building from `main`, which needs your GitHub account
(protected by your YubiKeys).

| File | Purpose |
|---|---|
| `recipes/recipe.yml` | What goes into the image |
| `files/system/` | Copied to `/`: Trivalent policies, `myblue-setup`, `verify-provenance.sh` |
| `files/scripts/` | Run at build time, not shipped: Proton Mail Bridge install, checks, `policy.json` additions |
| `files/keys/proton-bridge.asc` | Proton's Bridge signing key, for checking the Bridge RPM at build time |
| `.github/workflows/build.yml` | Daily build, base-image check, signing, provenance |
| `.github/dependabot.yml` | Weekly bumps for the pinned actions |
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
    blue-build/*, sigstore/*, regclient/*, slsa-framework/*,
    hastd/free-disk-space@*, docker/setup-buildx-action@*,
    docker/setup-qemu-action@*, google-github-actions/auth@*
    ```
    The last four are used inside BlueBuild's action and the SLSA
    generator. If a run fails at *Set up job* with "not allowed", add the
    action it names.
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
   first. The image already has your key and the two `docker.io` entries
   for podman, so anything the diff shows is either a newer secureblue
   change (keep the image's version) or a local edit you need to carry
   into the recipe.
   ```sh
   run0 cp /usr/etc/containers/policy.json /etc/containers/policy.json
   ```
4. **Remove leftover layering.** `rpm-ostree status` lists packages you
   had layered that are now in the image as inactive requests. Remove
   them with `rpm-ostree uninstall <pkgs>`.
5. **Test the update check:** `/usr/libexec/secureblue/verify-provenance.sh`
   should exit 0 and print a `PASSED` line from slsa-verifier.

On a fresh machine, install stock secureblue first, then start at step 2.
That way secureblue's first-boot cleanup has already run.

## Proton Mail Bridge

Proton has no dnf repo for Bridge, only a signed RPM.
`files/scripts/install-proton-bridge.sh` reads Proton's version feed,
downloads the current RPM, requires a valid signature from the key in
`files/keys/` (fingerprint `D51E 64D3 E63E DC3E EF78 64CE E2C7 5D68
E623 4B07`), and installs it. Each daily build picks up the latest Bridge.

Autostart is Bridge's own *Open on startup* setting, not a service you
write: it adds an XDG autostart entry (`protonmail-bridge --no-window`),
which COSMIC runs as a systemd user unit and lists under *Startup
Applications*. Don't add Bridge there by hand: that copy starts without
`--no-window`. Turn off Bridge's *Automatic updates*: its launcher would
otherwise run newer versions it downloads into your home folder instead
of the image's. `myblue-setup` lists both settings, and Peergos's
equivalent, *Start on boot*.

## Day to day

- **Change the config:** make a signed commit (your `.gitconfig` signs by
  default) and push. The image builds and arrives with the next automatic
  update, then a reboot.
- **Dependabot PRs:** check what changed in the action, then merge. Merging
  in the web UI is fine; GitHub signs the merge commit.
- **The build fails at "Verify secureblue base image":** secureblue's
  image failed its signature or provenance check, or secureblue rotated
  its key. Nothing gets built or published, so your machine stays on its
  current image. Only update `keys/secureblue.pub` once you've confirmed
  the rotation through secureblue's official channels.
- **The build fails in `install-proton-bridge.sh`:** either the download
  failed its signature check, or Proton changed its feed or rotated its
  key. Nothing is published. Only replace `files/keys/proton-bridge.asc`
  once Proton has announced the new key on its official site.
- **Updates stop arriving:** `journalctl -u rpm-ostreed-automatic` shows
  why. secureblue also warns you once the system is a week out of date.
- **Following secureblue's BlueBuild versions:** Dependabot can't bump the
  BlueBuild CLI (`cli_version` in `build.yml`) or the modules image digest
  (`source:` on each module in the recipe). When secureblue bumps them, in
  `.github/workflows/build-one-recipe.yml` and
  `recipes/common/common-modules.yml` on their `live` branch, copy the new
  values.
- **`ujust audit-secureblue`** reports `policy.json` as modified (INFO) and
  warns about the two `docker.io` scopes. That's expected. Don't copy your
  policy over `/usr/share/secureblue/etc/containers/policy.json` to silence
  it: the audit would then stop checking the policy at all.

## Limits, the same as secureblue's own

- Your GitHub account is the root of trust. Anyone who controls it can
  build from `main`, which is why it's protected by your YubiKeys.
- The provenance check runs on the two normal update paths. Typing
  `rpm-ostree upgrade` by hand skips it, and then only the cosign
  signature is checked.
- The checks look at the digest `latest` points to, and the image is
  fetched a moment later. secureblue's updater has the same small window.
- Once `policy.json` can match GitHub workflow identities (upstream work
  in progress), rpm-ostree could enforce the provenance check itself.
