<!-- SPDX-FileCopyrightText: Copyright (c) respective contributors -->
<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Devario boot and initramfs

Devario owns its boot lifecycle. `devario-dracut` builds pinned upstream dracut
112 and provides the compatible `dracut` and `initramfs` package capabilities.
`devario-boot` owns configuration, kernel discovery, initramfs generation,
recovery files, and Limine deployment. Shelly's ALPM hooks are transaction
adapters; the generator does not call a package manager or require Arch identity.

The kernel recipe installs `/usr/lib/modules/<release>/devario-kernel` as data:

```text
version=<release>
image=vmlinuz
id=linux-devario
```

The version must match its containing directory and the image is relative to
that directory. The compatibility adapter accepts `pkgbase` when native metadata
is absent. Missing/ambiguous kernels and malformed metadata stop generation.
Additional kernel IDs require an explicit selection and bootloader integration;
repository compatibility alone does not enable every external kernel.

The builder invokes `/usr/lib/devario/initramfs-update --mode live` after package
hooks, DKMS, and overlays, before copying boot files. This always produces a
generic image with embedded microcode. The pinned `devario-iso-builder` assembles
BIOS/UEFI media from a declarative profile. Every invocation requires a fresh
work directory; no cached package-install stages are reused.

Calamares copies `/run/devario/install-root`, a read-only bind of dracut's
pristine `/run/rootfsbase`. It never copies the writable live overlay. The source
remains available in copy-to-RAM mode (`rd.live.ram=1`), after the boot media is
unmounted. Live discovery uses `root=live:UUID=...`, `rd.live.dir`, and
`rd.live.squashimg`. Loopback boot uses `iso-scan/filename`.

After configuring target storage, crypttab, fstab, and the kernel, Calamares calls
`/usr/lib/devario/boot-update --install`. Subsequent Shelly transactions call
`boot-update` without that flag. An installation marker suppresses installed
boot updates during live-image assembly. Generation runs after DKMS hooks and
before Limine inside one process, so failed generation cannot refresh Limine.
The package disables competing generator hooks in `/etc/shelly.d/hooks`.

Installed generation creates a host-only default and generic fallback. Both use
the explicitly selected target kernel and omit the live modules and captured
host command line. Limine supplies root, encryption, Btrfs subvolume, and resume
arguments from target configuration. Initramfs files embed early microcode;
Limine does not load a second external microcode image.

Calamares validates NVIDIA 615.71.09 hardware compatibility and the offline
payload before partitioning. After copying it, the installer verifies/builds
the target kernel's NVIDIA modules and sets `NVIDIA_EARLY_KMS="true"` in
`/etc/devario-dracut.conf`. Installed generation honors this flag, checks all
four modules in the selected kernel tree, and forces early loading with DRM
modesetting. Both generated images must contain the modules, their declared
firmware, and modesetting configuration before either image is published.
Live generation ignores this installed-system setting. Driver and firmware
updates use the same checks through the existing post-DKMS boot hook.

Generation requires mounted `/boot`, holds a lock, stages files on the boot
filesystem, and inspects them with `lsinitrd` before publishing. Errors during
publication attempt to restore the old files. This is not a filesystem-wide
transaction across power loss or a rollback of the package manager's changes.

The first replaced kernel/image pair is saved under
`/boot/devario-recovery/linux-devario/`, published with one directory rename;
Limine exposes it as a recovery entry. Further transactions retain that pair. After confirming
a successful reboot, an administrator can archive or remove that saved directory
to allow the next transaction to preserve a newer pair. The previous image is
boot recovery, not a snapshot of the whole installation or its module tree.

For an installed system, rebuild with:

```sh
sudo /usr/lib/devario/boot-update
```

The lower-level generator accepts `--mode`, `--kver`, `--kernel-id`,
`--modules-root`, `--boot-dir`, `--config-dir`, and `--automation-config`.
The last overrides `/etc/devario-dracut.conf` for installed generation.
Default policy files live in
`/usr/share/devario/dracut/`. Use an explicit configuration directory for custom
generation; never regenerate an installed image with the live configuration.

HTTP/NFS/NBD entries require CMS verification (`rd.devario.verify=1`). HTTP
fetches `<image-url>.cms.sig`; NFS and NBD use the adjacent signature. To produce
signed network media with the development ISO wrappers, supply
`DEVARIO_LIVE_SIGNING_CERT` and `DEVARIO_LIVE_SIGNING_KEY`. The public certificate
is embedded in the initramfs; the key remains outside the image. The NBD export
is named `devario` and exposes the ISO. The NFS example serves the extracted ISO
under `/devario`; adapt that export path to the server. Unsigned or tampered
network images fail verification. Local USB/optical boot does not require CMS.

Before migrating an existing installation, save its matching kernel, initramfs,
and Limine configuration outside filenames subject to package removal hooks.
Replace the provider and install `devario-boot` in the same dependency-resolved
Shelly transaction, then run `boot-update`. Verify both boot entries and retain
installation media for recovery. Custom presets, keyfiles, external kernels,
and storage layouts require individual review; no automatic conversion of
arbitrary mkinitcpio shell configuration is performed.

Validation commands:

```sh
./tests/test-dracut-boot.sh
./scripts/validate.sh
./tests/test-release-metadata.sh
./tests/test-dracut-live-qemu.sh /path/to/kernel /path/to/live-initramfs
```

The QEMU probe builds a tiny temporary ISO and directly boots the supplied
kernel/initramfs. It verifies writable live root, read-only/pristine installation
source, and copy-to-RAM media release. Set `DEVARIO_TEST_ACCELERATOR=kvm` when
the binaries require host CPU features unavailable under TCG. This probe does
not validate the complete desktop ISO, BIOS/UEFI bootloaders, Calamares installs,
encrypted installed roots, or network boot. The full candidate acceptance matrix
in `IMAGE-ACCEPTANCE-MATRIX.md` remains required for release.
