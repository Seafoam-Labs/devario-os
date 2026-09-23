<!-- SPDX-FileCopyrightText: Copyright (c) respective contributors -->
<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Devario ISO independence implementation plan

Status: source implementation is present, including the private builder
repository, identity/packages, default repositories, optional compatibility,
and versioned build contracts. Package and BIOS/UEFI media tests have passed.
Full desktop ISO construction and installed-system acceptance remain pending
complete signed package/bootstrap inputs and a privileged build environment.
See [implementation and verification](ISO-BUILDER.md).

Devario owns distribution identity, repository policy, and image construction.
Shelly provides optional repository compatibility. Dracut and `devario-boot`
retain ownership of initramfs generation and the live/installed boot contract.

## Decisions and boundaries

- Use a separate private `Seafoam-Labs/devario-iso-builder` repository for the
  assembler, subject to verifying the owner and existing repository during
  implementation. This owner follows the current `devario-os` origin. Reuse an
  existing suitable repository; otherwise create it with private visibility.
- Implement a focused Devario assembler with a versioned interface. Port only
  required, understood assembly operations from the pinned implementation where
  useful, preserving their attribution. Do not retain `mkarchiso` as a hidden
  backend or import unrelated Arch profiles and packaging policy.
- Keep edition composition, package selection, repository trust, and release
  authorization in `devario-os`. Keep boot generation in `devario-boot`.
  The builder owns staging, filesystem/media assembly, and build reports.
- Preserve x86_64, BIOS Syslinux, UEFI systemd-boot, the current dracut live
  layout, Calamares installation, and installed Limine. Preserve shipped
  loopback/network boot functionality and public-certificate signing behavior.
  This work does not introduce a bootloader or UKI migration.
- Keep upstream source URLs, license notices, and truthful package provenance.
  Removal targets active Arch identity and mandatory Arch integrations, not
  every historical or third-party occurrence of the word "Arch".

## 1. Establish Devario-owned identity

Remove `ID_LIKE=arch` from both `iso/airootfs/etc/os-release` and the Managed
overlay's `airootfs/etc/os-release`; omit `ID_LIKE` rather than inventing another
distribution relationship. Preserve edition-specific names and release fields.

Audit the selected `filesystem` package and other owners of `/usr/lib/os-release`,
`/etc/os-release`, `/etc/arch-release`, `/etc/lsb-release`, `/etc/issue`, and login
banners. Put base identity files in a Devario-owned filesystem/identity package;
resolve package ownership and upgrades explicitly so a compatibility package
cannot restore Arch identity. Keep edition rendering as the final authority for
edition and release values, with a defined relationship between the two
`os-release` locations. Remove inherited Arch marker files where present.

Update release-identity validation and Managed replacement rules. Generate the
initramfs after identity is finalized and check its embedded release information.
Verify both a live session and an installed target retain Devario identity after
a package upgrade.

Exit condition: Community and Managed identify as Devario in the live root,
initramfs, and installed target; package operations preserve that identity.

## 2. Replace shipped boot configuration names

Rename `iso/syslinux/archiso_*.cfg` to `devario_*.cfg` and update every
`INCLUDE` and `CONFIG` reference. Change remaining shipped comments that describe
Archiso as the live-root owner, including the comment in `devario-boot`'s
`limine-update`.

During builder integration, migrate template substitutions such as
`%ARCHISO_UUID%` to the Devario builder's documented names. Update the renderer
and templates together; reject unresolved placeholders in generated boot files.
Audit generated GRUB configuration and embedded EFI configuration as well as the
checked-in templates. Preserve dracut arguments and `/run/devario/install-root`.

Exit condition: shipped boot filenames and active configuration use Devario
names, and all referenced kernels, initramfs files, and included configs exist.

## 3. Make ISO metadata explicitly Devario-owned

Replace the inherited `prepared by mkarchiso` preparer value with
`prepared by devario-iso-builder`. Preserve edition-controlled volume label,
publisher, application, filename, and version. Record the exact builder version
and source digest in the build report rather than relying on a display string
for provenance.

Check metadata using the completed ISO, including the boot catalog and firmware
images. Keep the existing `/devario` media directory and current live filesystem
filename unless a functional change requires otherwise.

Exit condition: ISO metadata reflects the selected Devario edition and can be
traced to the pinned builder input.

## 4. Isolate Arch repository compatibility behind Shelly

Use both `devario-core` and `seafoam-labs`, hosted at
`https://repo.seafoam-labs.org`, as default repositories for Community and
Managed builds and installed systems. Give `devario-core` priority for the
distribution's base, identity, and boot packages; use `seafoam-labs` for the
shared Seafoam Labs package set. Managed adds its separately declared repository.

The site's [setup documentation](https://repo.seafoam-labs.org/setup) currently
documents `[seafoam-labs]` with
`Server = https://repo.seafoam-labs.org/$arch`. Confirm the exact `devario-core`
server/database path and each repository's signing-key fingerprint using the
service's repository metadata before implementing configuration. Do not infer
a path or shared trust root from their common hostname. Record the verified
endpoints and public-key bundles in the repository contract.

First inventory every runtime package and transitive dependency currently
resolved from Arch `core`/`extra`, plus build dependencies and bootstrap inputs.
Check coverage in both `devario-core` and `seafoam-labs`; produce a
package/source/trust inventory identifying each provider and any missing
dependencies. Build and publish missing packages into the appropriate repository
under the existing signing and source-retention process. Do not merely remove
repositories from an incomplete package configuration or relabel upstream
packages as native builds.

Then make these coordinated changes:

- Remove mandatory `archlinux-keyring` from `devario-base` and
  `pacman-mirrorlist` from `devario-alpm-runtime` once closure is satisfied.
  Rename the shipped ALPM account description to a Shelly description.
- Change both ISO Shelly templates and the configuration shipped by
  `devario-alpm-runtime` to enable `devario-core` and `seafoam-labs` by default,
  with explicit precedence and protected-package ownership. Community trusts
  the verified signing keys for both repositories; Managed additionally trusts
  its separately declared repository key.
- Initialize the selected `devario-core` and `seafoam-labs` trust roots in
  `shelly-keyring-init.service` and the default build path, plus the Managed key
  only for that edition. Remove mandatory host Arch keyring checks.
- Introduce an optional `shelly-arch-compat` package/profile containing the
  external repository configuration, mirrorlist, and keyring dependencies.
  Installing it makes compatibility available; explicit activation enables its
  repositories and trust. Define precedence so external repositories do not
  silently replace protected Devario base, identity, or boot packages.
- Verify activation, deactivation, and upgrades without deleting user-managed
  configuration. Deactivation stops future use of external repositories; it
  must report already installed external packages rather than promise to undo
  their installation. Audit the versioned `pacman` compatibility provide and
  retain only compatibility metadata actually required by supported packages.

The controlled build path also currently requires an Arch bootstrap and an
`archSnapshot` lock field. Version the lock/manifest schemas and their consumers
to describe named, pinned repositories and independently verified bootstrap
inputs. Supply a Devario-controlled bootstrap and dependency set for the final
default path, drawing packages from `devario-core` and `seafoam-labs`. Extend
repository/keyring schemas, input staging, and boundary checks to accommodate
both default repositories plus the optional Managed repository. Lock each
repository's package/database inputs and signer identity separately, even if
they share a host or verified signing key. Preserve exact hashes, signatures,
signer identities, repository boundaries, and rejection of mutable inputs.
Update package builders, ISO
wrappers, Managed lock validation, and test fixtures together. Legacy evidence
must remain identifiable by schema version; do not silently reinterpret it.

Exit condition: default package/image builds and installed updates resolve
against `devario-core` and `seafoam-labs` at `https://repo.seafoam-labs.org`
(plus the declared Managed repository for that edition), without required Arch
trust or access to Arch repositories. Verify both default repositories are
configured, their package coverage is sufficient, and their signatures and
precedence are enforced. A separate compatibility fixture demonstrates optional
Arch access.
An Arch-based development host may remain supported, but cannot be required by
the image builder's interface.

## 5. Deliver and integrate devario-iso-builder

### Repository and interface

Prepare the implementation and repository documentation locally, then create or
reuse the private GitHub repository during implementation. Verify actual private
visibility and push only builder sources, tests, and fixtures. Keep credentials,
release signing keys, generated roots, and customer edition data outside it.

Define a versioned declarative manifest and CLI covering architecture, composed
root/profile inputs, verified package input locations, Shelly adapter, kernel
and initramfs outputs, firmware modes, image metadata, compression, epoch,
work/output directories, and optional media signing. Reject unknown fields and
unsupported modes. Repository URLs and trust policy come from the caller; the
builder does not choose distribution repositories or source arbitrary profile
shell code. Document privileges and host tools explicitly.

### Assembly stages

1. Validate inputs and tool capabilities; allocate a dedicated work directory
   and arrange reliable teardown of mounts on failure and interruption.
2. Populate the root through Shelly using the selected configuration and keyring.
   Check actual installed inventory against requested packages, retaining the
   existing protection against successful partial installations.
3. Apply ordinary and late overlays in their required order, preserve file
   ownership/modes, and keep live-only user creation out of the pristine root.
4. Finalize release metadata; invoke the target's `devario-boot` live generator
   with target kernel metadata. Handle embedded microcode consistently. Pass
   only public verification certificates into the target root.
5. Stage and validate boot files before cleaning the packaged root. Create
   SquashFS, the BIOS boot layout, and the UEFI FAT/El Torito layout; assemble
   hybrid USB/optical media using explicit tools such as `mksquashfs` and
   `xorriso`. Carry over required checksums and optional media signatures.
6. Emit the ISO, package inventory, builder/input provenance, checksums, and a
   machine-readable report. Publish final outputs only after successful checks;
   failed builds must not leave an apparently valid final ISO.

Initially require fresh work directories. Add caching only with complete input
invalidation; existing Archiso stage markers must never be reused.

### Integration and cutover

Consume a pinned builder source archive by immutable revision and SHA-256, with
its license/provenance in the source manifest. Authenticate private retrieval
outside the target root and provide an offline cache path. Preserve the existing
release corresponding-source procedure; private development hosting does not
replace release source retention or source availability.

Replace extraction/patching/invocation of Archiso in `scripts/build-iso.sh` with
the new interface. Update both nspawn wrappers to install explicit required
tools instead of relying on the `archiso` package's dependencies. Bind builder
identity into controlled-builder manifests, input locks, and image build records.

Rename the core `archiso/` profile directory to `iso/`; update composition,
validation, CI, documentation, scripts, and Managed core-path restrictions.
Retain edition overlay relative paths where their meaning is unchanged. Update
Managed's `base.lock` only after the tested core revision is committed, using the
normal lock procedure.

Retire `tools/devario-archiso/` and its four patches only after their behavior has
been ported and verified. Keep the previous implementation retrievable through
version control for regression diagnosis, without a silent release fallback.

Exit condition: the normal build path invokes the pinned Devario builder and
has no installed or vendored Archiso dependency.

## Delivery order and verification

1. Capture the current package/boot contracts and available baseline evidence;
   start the package dependency inventory.
2. Implement identity ownership and shipped configuration renames with focused
   identity/composition tests. Prepare the builder contract and repository.
3. Implement the assembler and Devario metadata; prove a development image with
   explicit transitional repository inputs before changing package sourcing.
4. Complete Devario package/bootstrap coverage, optional Shelly compatibility,
   and versioned lock/manifest changes. Then switch defaults.
5. Integrate the pinned builder, rename the profile tree, remove the legacy
   assembler, and finish Community/Managed acceptance and release evidence.

For each stage, run relevant existing validation and meaningful contract tests.
Final acceptance requires a clean complete ISO build, inspection of ISO/root/
initramfs/EFI contents, BIOS and UEFI boots to the desktop, copy-to-RAM/media
removal, installation and reboot, and installed package/boot updates. Exercise
shipped network/loopback modes and signing where enabled. Check failure cases
for missing packages, invalid signatures, unresolved templates, and failed image
generation. Verify the default build works with external Arch repositories
unavailable; test compatibility separately. Compare inventories and behavior,
not byte equality between different builders.

Existing dracut package and isolated VM checks are useful evidence, but the full
desktop ISO has not yet been verified in the current work. Its known execution
prerequisites are a complete signed package repository and a usable privileged
build environment. Record those as pending until supplied and tested; do not
mark the migration complete on source validation alone.
