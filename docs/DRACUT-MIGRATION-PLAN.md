<!-- SPDX-FileCopyrightText: Copyright (c) respective contributors -->
<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Dracut migration plan

Status: boot-stack source implementation is present. Package builds, source
validation, and isolated live-root/copy-to-RAM VM checks have passed. Full desktop
ISO construction, installed-system acceptance, network boot, and release evidence
remain pending. See [the implemented boot contract](DRACUT-BOOT.md).

Devario is an independent distribution. Shelly provides repository compatibility;
that compatibility does not make Arch's package hooks, release policy, kernel
metadata, or image builder the authority for Devario's boot behavior. This plan
treats the Arch-specific integrations currently in the tree as implementation
details to isolate or replace, not as the target architecture.

Replace mkinitcpio in both the live ISO and installed Devario systems, including
Community and Managed editions. Preserve the CachyOS LTS kernel, installed
Limine bootloader, live BIOS/UEFI support, supported storage configurations, and
the existing release-evidence requirements. Deliver the migration in the order
below, with live-boot feasibility established before the package switch lands.

The repository currently has three coupled integrations: Archiso live hooks,
Calamares target generation, and package-transaction boot updates. A package-list
replacement alone cannot complete the migration.

| Area | Current integration | Planned change |
| --- | --- | --- |
| ISO packages | `iso/packages.x86_64` includes `mkinitcpio` and `mkinitcpio-archiso` | Select Devario's dracut package, boot integration package, and live dependencies |
| Edition contract | `scripts/lib/edition.sh` makes both packages immutable | Protect the replacement boot stack |
| Live generation | `iso/airootfs/etc/mkinitcpio.conf.d/archiso.conf` and `etc/mkinitcpio.d/linux-cachyos-lts.preset` | Separate dracut live configuration and explicit generation step |
| Builder | Vendored Archiso v89 plus three patches in `tools/devario-archiso/` | Invoke Devario's generation command through a replaceable builder adapter |
| Installer | `initcpiocfg`, `initcpio`, and preset copying in Calamares | Target dracut configuration and generation before Limine |
| Installer source | `unpackfs.conf` copies `/run/iso/airootfs` | Preserve a stable mounted, pristine installation source under dracut |
| Installed boot | `usr/lib/devario/limine-update` consumes fixed kernel/initramfs names | Preserve names; verify encryption, subvolume, and microcode handling |
| Updates | Shelly loads `/usr/share/libalpm/hooks/`; Limine has a `95-` hook | Devario owns boot updates; Shelly hooks translate transaction events |
| Validation | `scripts/validate.sh` asserts mkinitcpio presets and Archiso paths | Assert dracut configuration and actual generated-image behavior |

1. **Define the Devario boot contract and ownership.**

   Package upstream dracut under Devario's source pinning, signing, dependency,
   and release policy. Add a `devario-boot` integration package owning image
   generation, kernel deployment, configuration, and boot-update orchestration.
   Dracut supplies the generator; Devario supplies distribution policy. Preserve
   upstream attribution and record exact source inputs in the release manifest.

   Define a shared `/usr/lib/devario/initramfs-update` command with explicit
   live/installed mode, target kernel version, configuration, and output paths.
   It must work inside the prepared target root without querying a repository,
   invoking a package manager, or assuming Arch identity. The image builder,
   installer, recovery workflow, and Shelly transaction adapter use this same
   implementation. Define an orchestrated boot-update entry point that deploys
   the matching kernel, generates and validates images, and refreshes Limine
   only after successful generation.

   Specify Devario kernel metadata containing the kernel release, module tree,
   kernel image path, and output identifier. Have the Devario kernel recipe
   install it. Keep an explicit adapter for compatible repository kernels that
   expose `pkgbase`; translate that input into the same contract. Dependency
   provider names such as `initramfs` remain packaging compatibility metadata,
   not the generator's discovery API. Supporting repository formats does not
   automatically qualify every external kernel or package hook for Devario.

   Keep Archiso's current media assembly behind a builder adapter for this
   migration. The Devario contract must define root layout, boot inputs, and
   generation independently so another builder can consume it. Replacing the
   entire media assembler can be a separate implementation task; the dracut
   migration must remove reliance on Archiso's initramfs hooks and runtime paths.
   Reuse of upstream tools does not transfer ownership of distribution policy.

   Exit condition: document the command interface, kernel metadata, configuration
   ownership, and failure semantics before implementing the integrations.

2. **Prove the live filesystem contract.**

   Select and lock the upstream dracut version used by Devario. Inspect its
   scripts, modules, dependencies, and configuration against that exact version.
   Audit compatible repository packages separately for competing hooks. For
   example, Arch's dracut package ships ALPM install/remove hooks; these are
   compatibility inputs to control, not Devario's default boot implementation.
   [Package file list](https://archlinux.org/packages/extra/x86_64/dracut/files/).

   Prototype upstream dracut live support with the existing direct SquashFS
   root at `devario/x86_64/airootfs.sfs` and a writable overlay. Start with
   `dmsquash-live` and the overlay support required by the selected version.
   Map ISO discovery and image location to dracut's documented live arguments;
   do not assume `archisosearchuuid`, `archisobasedir`, or Archiso PXE arguments
   are understood. Dracut documents configurable image paths and copy-to-RAM
   support. [Boot arguments](https://man.archlinux.org/man/dracut.cmdline.7.en).

   Establish `/run/devario/install-root` as a Devario-owned, read-only mount of
   the pristine root used by Calamares. Determine the correct dracut backing
   mount from the prototype; add a small adapter only where necessary. Keep
   this mount available across switch-root and copy-to-RAM/media removal. Never
   point unpackfs at the writable live session or a disappearing media mount.
   Preserve the late-overlay live-user behavior and target cleanup.

   Inventory the shipped GRUB loopback and Syslinux HTTP/NFS/NBD entries as
   well as normal USB/optical boot. Record equivalent dracut boot arguments,
   required modules, and integrity-verification behavior for each. Existing
   `cms_verify=y` semantics must not silently disappear. Treat any unsupported
   mode as an explicit scope decision before release; do not leave broken menu
   entries. If upstream modules cannot preserve a required behavior, specify a
   narrowly scoped Devario live module and its maintenance cost before proceeding.

   Exit condition: experimental BIOS and UEFI live boots reach the desktop,
   expose the pristine installation source, and support installation after
   copying to RAM and removing the media. Document the selected module set and
   runtime paths so later steps use a demonstrated contract.

3. **Implement generation and package-update adapters.**

   Keep these installed paths: `/boot/vmlinuz-linux-cachyos-lts`,
   `/boot/initramfs-linux-cachyos-lts.img`, and
   `/boot/initramfs-linux-cachyos-lts-fallback.img`. Keep separate kernel and
   initramfs files; a UKI or bootloader migration is outside this change.

   Select the target kernel from the Devario metadata defined in step 1. Refactor
   `prepare-target-kernel` to use the shared selection logic; preserve its
   deterministic selection and rejection of missing or ambiguous kernel trees.
   Pass the version and output path explicitly to dracut. Never use the build
   host's `uname -r`. `packages/linux-cachyos-lts/PKGBUILD` already depends on
   `initramfs`; have Devario's dracut package satisfy that provider and retain
   `pkgbase` for compatible tooling. Existing filenames are a compatibility
   choice for this migration, not a requirement for future kernel packages.

   Use a generic live image with no captured host command line. For installed
   systems, generate a host-only default image using target mounts/configuration
   and a generic fallback, both without the installer's live command line.
   Validate host-only detection inside Calamares's chroot before adopting it.
   Include required storage, filesystem, encryption, keyboard, firmware, and
   GPU modules explicitly where autodetection is insufficient. Dracut exposes
   separate host-only image and command-line controls.
   [Configuration reference](https://man.archlinux.org/man/dracut.conf.5.en).

   Ship thin Devario-owned Shelly hooks that translate transaction events into
   the shared boot-update command. Check kernel install/upgrade/removal,
   microcode and dracut updates, DKMS completion, and depmod through actual Shelly
   transactions. Coalesce generation so each affected kernel is rebuilt once
   after its modules are ready. Integrate or replace the independent
   `95-devario-limine.hook` so it cannot run past a failed generation step.

   Do not ship a second generator policy inherited from a compatible repository.
   Use Shelly's configured hook override mechanism to suppress competing hooks
   where necessary; test precedence, package upgrades, and removals. Inspect
   external scripts for unavailable executables and assumptions about paths.
   Keep accepted package formats and ALPM event handling inside the adapter;
   boot generation must also work when invoked directly without those hooks.

   Guard installed-system hooks during live-root assembly. Build into temporary
   files on `/boot`, validate with `lsinitrd`, then publish; preserve a matching
   known-good kernel/image set for recovery. A failed generation must prevent a
   subsequent Limine refresh from reporting a successful boot update. Test
   Shelly's post-transaction error propagation rather than assuming hooks roll
   back the package transaction. Check `/boot` is mounted and has enough space.

   Choose one microcode policy for each image type. Prefer embedded early
   microcode for generic live media; inspect Archiso's existing detection and
   external-image handling, and avoid redundant installed Limine microcode
   entries if the installed images also embed it.

4. **Integrate the ISO builder and package selection.**

   Add a fourth vendor patch that invokes Devario's live generation command
   after package installation, DKMS/depmod, and relevant overlays, but before
   Archiso copies boot files or inspects microcode. Archiso v89 currently copies
   images already present in `/boot`; it does not provide the complete proposed
   dracut generation contract. Keep generation policy in `devario-boot`, not
   inside the vendor patch. Ensure resumed builds cannot reuse a stale initramfs
   when its inputs change.

   Wire the patch into `scripts/build-iso.sh`, source validation, and the vendor
   README. Keep the pinned Archiso archive unchanged. Install live configuration
   in a way that cannot influence installed-system rebuilds, and register any
   executable helpers in `iso/profiledef.sh` permissions.

   Replace the two mkinitcpio packages in `iso/packages.x86_64` with the
   Devario dracut and boot integration packages, update the immutable package
   set in `scripts/lib/edition.sh`, and remove obsolete live
   configuration/presets once their replacements are working. Update BIOS,
   UEFI, loopback, and network boot configurations together. Confirm the final
   package closure contains no accidental mkinitcpio provider.

   Rebuild repository/input locks and controlled-builder evidence through the
   existing tooling. `repository-packages.x86_64` is currently an untracked local
   file containing mkinitcpio entries; establish its provenance before treating
   it as an authoritative input or modifying it. Update source manifests and
   licensing records for any newly vendored code.

   Lock the boot packages to Devario's selected artifacts and trust roots. Test
   that enabling a compatible external repository cannot silently replace boot
   policy through package selection or hook collisions. A full inventory and
   removal of unrelated repository dependencies belongs to distribution-wide
   work; this migration establishes that boundary for the boot stack.

5. **Switch Calamares and installed-system boot.**

   Remove `initcpiocfg` and `initcpio` from `settings.conf`. Configure dracut
   after target kernel/configuration preparation and before
   the Limine installation step. Use a dedicated shellprocess job calling the
   shared Devario command with the target configuration, so the installer does
   not own another generation policy. Inspect Calamares 3.4.2's `dracutlukscfg`
   module for target encryption configuration; it and the `dracut` module are
   currently excluded by `packages/calamares/PKGBUILD`. Enable the configuration
   module if needed, or provide equivalent target configuration in Devario's
   preparation helper. Bump the package release when the module build changes.

   Replace preset installation in `prepare_target.conf` with installed dracut
   configuration, remove live-only configuration, and delete the unused
   `initcpio.conf`, `initcpiocfg.conf`, and installed preset template. Change
   `unpackfs.conf` to the proven installation-source mount. Update the
   acceptance self-check's live/installed detection, which currently checks an
   Archiso-specific path.

   Exercise Limine root UUIDs, mapper names, `rd.luks.name`, crypttab generation,
   Btrfs subvolumes, and recovery entries with the selected dracut/systemd
   modules. Cover encryption even when fstab identifies the decrypted root by
   filesystem UUID rather than `/dev/mapper/...`. Check all filesystem choices
   currently offered by Calamares: Btrfs, ext4, XFS, and F2FS. Include swap and
   resume configurations exposed by the installer, including Btrfs swapfile
   handling where applicable. Do not equate a successful build with successful
   unlock or resume.

6. **Validate behavior and release evidence.**

   Replace the preset/path assertions in `scripts/validate.sh`; extend edition
   composition, target-kernel, acceptance self-check, image-boundary, and
   controlled-builder tests where their contracts change. Add focused tests for
   target kernel selection, live/installed configuration isolation, hook ordering,
   generation failure, and preservation of recovery artifacts.

   Verify the shared command using Devario kernel metadata without `pkgbase`,
   an Arch release identity, Arch mirror/keyring configuration, or ALPM hook
   execution. Test the `pkgbase` compatibility adapter independently. Run the
   boot-update workflow with compatible repositories enabled and disabled, and
   prove foreign generator hooks cannot cause duplicate or conflicting writes.
   These tests validate boot-stack independence; they do not claim that every
   existing distribution-wide repository dependency has been removed.

   Inspect generated images with `lsinitrd`: expected kernel/modules, required
   storage and crypt support, intended microcode, no build-host or live-root
   command line in installed images, and no live modules in installed images.
   Perform clean builds using the locked inputs and compare outputs under the
   repository's reproducibility policy.

   Run `./scripts/validate.sh`, `./tests/test-release-metadata.sh`, and the
   relevant existing/new tests. Pass the exact-candidate live BIOS/UEFI and
   Calamares-installed BIOS/UEFI matrix using `scripts/test-image-boot.sh`.
   Extend coverage to encrypted/plain root, each offered filesystem, default
   and fallback boot, copy-to-RAM installation, and retained network/loopback
   modes. Test kernel, dracut, microcode, NVIDIA DKMS, and Limine updates followed
   by reboot; inject generation failure and a missing/full `/boot` condition.

   Re-run Managed composition against the accepted core commit by updating its
   `base.lock`, then collect both editions' required evidence. Retain the
   graphical installation review and appropriate real-hardware checks. Update
   `README.md`, `docs/architecture.md`, `docs/IMAGE-ACCEPTANCE-MATRIX.md`, the USB
   guide, and recovery instructions with the demonstrated behavior.

7. **Roll out new images, then migrate existing installations.**

   Release only after the complete new-install path and package-update path
   pass. If deployed systems exist, provide a separately tested migration
   transaction: inspect custom presets/hooks and storage setup; preserve a
   bootable old kernel/image pair and recovery entry; replace the initramfs
   provider without an unsatisfied kernel dependency; generate and inspect both
   dracut images; refresh Limine; verify reboot before removing saved recovery
   artifacts. Handle package conflicts and removal hooks explicitly so they
   cannot delete the newly generated images.

   Document rollback using the saved pair and bootable installation media.
   A generic fallback generated by dracut is not a backup of the previous
   working kernel/initramfs. Keep the previous released ISO and its evidence
   available until migration validation is complete.

Completion means both editions build and boot with dracut, installation and
subsequent updates produce working default/fallback images, supported boot and
storage paths pass, recovery is demonstrated, and active package/configuration
paths no longer require mkinitcpio. Devario owns kernel metadata, generation,
boot-update ordering, and release policy; Shelly repository compatibility is
an adapter to that contract. Historical documentation and untouched upstream
archive references may still mention mkinitcpio or Arch tooling.
