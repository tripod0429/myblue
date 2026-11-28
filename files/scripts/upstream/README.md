# secureblue package hardening

These scripts are unmodified copies of `files/scripts/` from
[secureblue commit `353366bb6d031e66fc565b0b101a8a069f32fcdb`](https://github.com/secureblue/secureblue/tree/353366bb6d031e66fc565b0b101a8a069f32fcdb/files/scripts).
Their SPDX copyright and license notices are retained; `LICENSE` is the
upstream Apache 2.0 license.

The recipe runs the package cleanup and checks from upstream's
`recipes/common/final-modules.yml`, in upstream order, after all custom
package installations:

- `remove-pdf-thumbnailers.sh`
- `checksinglekernel.sh`
- `removesuid.sh`
- `removesudo.sh`
- `ensure-packages-absent.sh`
- `check-selinux-fcontext.sh`
- `libdnf5-clear-history.sh`

Image generation and service presetting have already run in the base image.
We do not regenerate its metadata or initramfs, and especially do not run
`backupetc.sh`: retaining the original audit baseline keeps our container
policy exceptions visible to `ujust audit-secureblue`.

`removesudo.sh` decides from `IMAGE_NAME`, which is this recipe's name
(`myblue`), not the base image's. On the COSMIC base it removes sudo just as
upstream does. On a Kinoite base it would remove sudo where upstream keeps it,
so check it before changing `base-image`.

When updating, compare these scripts and the final module with upstream,
replace the vendored copies from a reviewed commit, and update this reference.
Never download and execute scripts from the moving `live` branch during a build.
