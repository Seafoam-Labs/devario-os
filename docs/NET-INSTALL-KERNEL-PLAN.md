<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

**Devario network installation, kernel, Shelly, and desktop implementation plan**

Status: network installer migration proposed; `linux-devario` is now selected
by the ISO, installer, and boot paths. Kernel and dracut recipes are maintained
outside this OS repository and supplied as signed packages.
Shelly 3.1.6-2 with its native RLPM backend is now
supplied by `devario-core`; the local Shelly and ALPM runtime recipes are
retired. The desktop now uses published Aqueous/Pearl packages and Pearl Greeter.
The network installer migration remains unimplemented.
Repository inspection: 2026-10-02.

Make network installation provision Devario from signed packages in
`https://repo.seafoam-labs.org/devario-core/$arch`, and use the kernel from
[Seafoam-Labs/linux, release devario-7.2.7-1](https://github.com/Seafoam-Labs/linux/releases/tag/devario-7.2.7-1)
for both the live ISO and installed system. Include the latest stable Shelly
and select the desktop through `devario-desktop` in this same migration.

**Verified starting point**

- `repositories/defaults.json` already declares the requested repository with
  the architecture suffix. `scripts/build-iso.sh` already defaults to
  `https://repo.seafoam-labs.org/devario-core/x86_64`.
- The repository's `x86_64/devario-core.db` and `.db.sig` endpoints return HTTP
  200. The bare `/devario-core` URL returns 404; use the package endpoint.
  Availability was checked, but its signature and dependency closure have not
  been verified as part of this planning task.
- Calamares currently uses `unpackfs` to copy the pristine live root from
  `/run/devario/install-root`. There is no network package-installation step,
  and `packages/calamares/PKGBUILD` disables the upstream packages module.
- The kernel packages and boot identifiers are `linux-devario` and
  `linux-devario-headers`. Boot helpers, NVIDIA checks, and tests use this identity.
- Authenticated GitHub access confirms the kernel repository is private and
  `7.2/devario` is a branch. Its inspected commit is
  `fb04fd0acac8dbd8d13723e1fb28c1906380f7fe`; its Makefile reports **7.2.7**.
  The user subsequently selected the signed **devario-7.2.7-1** release tag,
  which resolves to `00a4b3afc99f9413ff9ad168c2fdbe3f788eb9e5`, as the packaging
  source instead of that branch-head revision. The release archive checksum and
  signature have been verified; full build and boot validation remain pending.
- The latest stable Shelly release inspected is **3.1.6**, tag `v3.1.6`, commit
  `d9d89773968a5a03beb5183c1101e0235e4f3524`. Its commit archive SHA-256 is
  `025329c8972e592b72fa7955bd6cea76ddd723278a9dfa148b83cae4f999c923`.
- The requested `devario-desktop` recipe lives in
  [Aqueous's packaging/devario directory](https://github.com/Seafoam-Labs/Aqueous/tree/e480bbfe2fc95d5c6468ecf51556415584cdf434/packaging/devario).
  At that revision it selects stable **Aqueous 0.9.1 and Pearl**, without
  Aqueous Welcome or DMS/Noctalia desktop integrations. The metapackage was not
  present in the inspected repository databases, although its stable Aqueous
  components and Pearl were present.

**Recommended scope and defaults**

Add an explicit network-install mode that provisions a fresh target root from
packages; retain the current offline mode as a separately selected option.
Do not silently fall back to offline installation on a network failure. Keep
Shelly as the package manager, dracut for initramfs generation, and the current
BIOS/UEFI media and installed Limine boot paths. Keep `seafoam-labs` available
for its existing package ownership, with `devario-core` first. Preserve edition
composition and Managed repository isolation.

Upgrade Shelly and replace the individual desktop selections as part of the
same network-install implementation and release acceptance. Apply the package
policy to both the live ISO and the fresh installed target so they do not ship
different package-manager or desktop defaults.

Use the proposed names `linux-devario` and `linux-devario-headers`, with kernel
ID `linux-devario`. Confirm these names against the repository publisher before
publishing the first artifacts. Private source access belongs to the build
environment; installation requires only the published signed packages.

**1. Establish the package and repository contract**

Use `repositories/defaults.json` as the source for installer and installed
repository configuration. Remove duplicated defaults where practical while
preserving explicit build overrides. Require package and database signatures
for network installation and installed operation; do not inherit the temporary
ISO build repository's relaxed verification settings.

Bootstrap trust from the reviewed `devario-keyring` and `seafoam-keyring`
material on the ISO. Verify the published database and package signatures
against that trust, rather than trusting a newly downloaded key automatically.

Define an installed-system package manifest separate from `iso/packages.x86_64`.
Include the base system, `devario-desktop`, current Shelly, networking, firmware,
boot components, new kernel and matching headers, and existing GPU support. Exclude live-session
and installer-only components. Apply edition additions, removals, and source
constraints to this manifest, and verify the complete dependency closure is
available from the allowed repositories before enabling the new mode.

Exit condition: a signed repository transaction can resolve every required
target package, including the desktop metapackage, updated Shelly, kernel, and
matching headers.

**2. Upgrade Shelly and adopt the Devario desktop metapackage**

Use Shelly from the signed `devario-core` snapshot, with 3.1.6-2 or newer as
the native RLPM baseline. `devario-base` retains Devario's runtime policy and
storage migration. Verify `/etc/shelly.conf`, `/var/lib/shelly`, keyring and
cache paths, and `SHELLY_ALPM_CONFIG` against the repository package. Cover
both absolute and target-relative hook/database paths in image acceptance.

Add the pinned upstream `devario-desktop` recipe and its checksummed
`session.toml` default. Its direct desktop dependencies are
`aqueous-core`, `aqueous-session`, `xdg-desktop-portal-aqueous`,
`aqueous-integration-pearl`, and `aqueous-shell-pearl`, pinned to `0.9.1-1`,
plus stable `pearl`. The default selects `shell = "pearl"`; existing user
configuration takes precedence.

Replace explicit Aqueous and DMS/Noctalia shell selections in the ISO and target
manifests with `devario-desktop`. Do not substitute the general
`aqueous-desktop` metapackage: it includes other integrations and Welcome.
The old local Aqueous and Noctalia recipes have been retired; their provenance
remains in Git history. The current desktop policy selects the published
Aqueous 0.9.1 Pearl components directly and supplies the Pearl session default.

Move GPU detection, installed greetd configuration, and Devario application
defaults out of the conflicting `devario-aqueous-desktop` package into a
separate support package. Keep the login greeter independent of the desktop
shell. Pearl Greeter now runs through its packaged `pearl-greeter.service`.
Coordinate this support package with the new kernel
headers; the current desktop package already selects `linux-devario-headers`.

Update `scripts/build-packages.sh`, `scripts/build-iso.sh`,
`scripts/lib/edition.sh`, `repository-packages.x86_64`, and validation together.
Protect the metapackage through edition composition. Check the new component
artifact layouts, including `etc/xdg/uwsm/env-aqueous`, and verify the packaged
Wayland session still launches through UWSM. Define an upgrade transaction for
existing systems that resolves the old package conflicts and file ownership
without leaving the old pinned desktop components installed as requirements.

Publish the metapackage, support package, and Devario-compatible Shelly build
before enabling the installer. The published generic Shelly package currently
depends on `pacman`; do not assume it preserves Devario's executable and runtime
path boundaries just because its version is current.

A preliminary database dependency audit selected 278 packages for the desktop
and reported unresolved `libgcc`, `libgcc_s.so`, `libgfortran`, `libgomp`,
`libquadmath`, and `libstdc++` requirements. Supply the packages and virtual
providers that satisfy these requirements, then repeat a signed transaction
audit. Database resolution alone does not verify signatures or conflicts.

Exit condition: the coordinated live/target package set resolves and installs
with the updated Shelly; Pearl starts through the metapackage's default; no
DMS/Noctalia desktop shell is pulled in by that dependency chain; and GPU/login
behavior remains functional.

**3. Package and publish the Seafoam kernel**

Maintain the external `linux-devario` recipe with a reviewed configuration and a split
kernel/headers PKGBUILD. Fetch the private source in an authenticated build
preparation step, pin the selected release tag and its full commit above, and
checksum the exact source artifact consumed by the controlled build. Keep credentials outside recipes,
source archives, logs, and images. Record the source commit, configuration hash,
toolchain inputs, and resulting kernel release in build evidence.

Audit the fork's configuration and patches before adapting the existing
CachyOS recipe. Target x86-64-v3 as requested and retain the required live-root,
storage, filesystem, networking, graphics, and dracut functionality. Do not
carry over CachyOS-specific patches or build switches without review.

Preserve the Devario package contract under `/usr/lib/modules/<release>/`:
`vmlinuz`, modules, `pkgbase`, and `devario-kernel` metadata with matching
`version`, `image=vmlinuz`, and `id=linux-devario`. Ship a usable headers tree
and verify NVIDIA DKMS compilation against this exact release.

Update `scripts/build-packages.sh`, `repository-packages.x86_64`, package
provenance, and corresponding-source records. Publish signed kernel and headers
packages together with their repository metadata. Follow the project's existing
corresponding-source process for distributed kernel binaries even though the
development repository is private.

Exit condition: the controlled build produces verified kernel and headers
artifacts, and the repository serves both with their required dependencies.

**4. Migrate every boot and build consumer**

| Area | Files and required change |
| --- | --- |
| Image selection | Update `iso/profile.json`, `iso/packages.x86_64`, and `packages/devario-base/PKGBUILD` to the new kernel identity. |
| Build preflight | Update kernel artifact requirements in `scripts/build-iso.sh`, protected edition packages in `scripts/lib/edition.sh`, and recipe/artifact checks in `scripts/validate.sh`. |
| Target preparation | Update `iso/airootfs/usr/lib/devario/prepare-target-kernel` and Calamares `modules/prepare_target.conf`. |
| Boot generation | Update `packages/devario-boot/initramfs-update`, `limine-update`, and `95-devario-boot.hook`, including fallback and recovery paths. |
| Live boot entries | Update `iso/syslinux/`, `iso/grub/`, and `iso/efiboot/loader/entries/` consistently. |
| Builder integration | Exercise the existing `kernelId` interface in `devario-iso-builder`; update fixtures. Change and repin the builder only if its implementation needs modification. |

Prefer a shared kernel identity where practical. Preserve metadata-based kernel
selection and rejection of missing or ambiguous kernel trees. Ensure boot
updates finish only after the matching modules, DKMS outputs, and initramfs are
ready.

For existing installations, define a separate tested upgrade transaction that
installs the new kernel and headers and generates its boot entry before removing
the old default. Retain a working recovery entry through the transition; avoid
an unconditional package replacement that removes the only bootable kernel.

Exit condition: the live ISO and installed target boot the new kernel under
both BIOS and UEFI, including fallback/recovery coverage.

**5. Implement Shelly-backed network installation**

Add the mode selection and execution branch to
`iso/airootfs/etc/calamares/settings.conf`. Supply a Devario Calamares module
with progress/error reporting and a packaged target-provisioning helper; do not
enable an upstream package backend that invokes Pacman. Update the Calamares
recipe only as needed for the chosen integration.

Before partitioning, check connectivity, usable system time, repository trust,
package availability, and space requirements. Freeze the resolved package set
and database digests for the installation. Prefer downloading and verifying the
resolved package archives before disk changes, with space checks for the cache.
Use an immutable published snapshot when available; otherwise require the
resolved artifacts to remain available and fail rather than silently changing
versions mid-installation.

After partitioning and mounting, initialize the target using an isolated Shelly
configuration with target `RootDir`, database, cache, logs, and hook paths.
Reuse the proven transaction pattern in `devario-iso-builder/builder.py`, which
uses `SHELLY_ALPM_CONFIG`, API filesystem mounts, and inventory checks. Keep
installer code in a runtime package instead of depending on the ISO assembler
at installation time. Ensure DNS access, hook execution, and cleanup work for
the mounted target without modifying the live system's package state.

Install the resolved target package set, verify its actual inventory, and apply
the edition's target configuration and identity. Audit configuration currently
provided only by `airootfs` and `late-airootfs`; package or explicitly apply the
required installed defaults so fresh-root installation does not lose them.
Populate the target's persistent trust store and repository configuration.

Run the remaining locale, account, network, service, and boot configuration
steps in their required order. Generate initramfs and Limine configuration only
after kernel installation succeeds. Adapt target preparation for both fresh
and copied roots. Bound retries, retain useful logs, and never report success
or proceed to bootloader installation after a failed package transaction.

Exit condition: network mode produces a complete, bootable target from repository
packages; offline mode still installs independently from the ISO.

**6. Extend release evidence, tests, and documentation**

Extend installation evidence to record installation mode, repository URLs and
database digests, resolved/installed package versions and hashes, kernel source
commit, and kernel configuration identity. Update installation lock/inventory
schemas and their generators/validators with an explicit schema migration where
needed. A network-installed system must not be assumed identical to the ISO's
package inventory.

Update kernel preparation, dracut boot, GPU, edition composition, image boundary,
repository closure, and release validation tests. Add focused installer tests
for target isolation, dependency closure, signature rejection, missing headers,
network loss, unavailable pinned artifacts, transaction failure, and cleanup.
Add Shelly patch application and upstream CLI/keyring/package-manager tests,
desktop dependency and file-ownership checks, Pearl session startup, and the
old-to-new desktop migration. Validate the actual metapackage dependency chain
instead of requiring the old individual desktop packages in the ISO manifest.

Run `scripts/validate.sh` and the applicable builder tests, then build a signed
candidate ISO. Exercise actual Calamares network and offline installs in BIOS
and UEFI VMs. Reboot each installed disk without the ISO; check `uname -r`, kernel
metadata, repositories, package inventory, desktop login, networking, and a
subsequent kernel upgrade. Test NVIDIA DKMS and driver loading on suitable
hardware; VM boot alone does not establish GPU compatibility. Verify Community
and Managed edition contracts.

Update `README.md`, `docs/ISO-BUILDER.md`, `docs/DRACUT-BOOT.md`, installation
instructions, acceptance matrices, and provenance. Replace outdated claims that
all installations only copy the live filesystem.

`scripts/validate-kernel-package.sh` checks the Seafoam Labs kernel source and
configuration pins in an explicitly supplied external recipe directory.
The relocated dracut package must retain Devario's executable boundary; inspect
its hooks and runtime commands in that package's source and built artifacts.
Install `jsonschema` in the validation environment so
the release-contract tests actually execute.

**Delivery order and completion criteria**

Deliver one coordinated network-install change in reviewable steps:
repository/target manifest contract; Shelly and desktop migration; kernel
packaging and publication; boot identity migration; network installer; release
evidence and acceptance results. Do not roll out the Shelly or desktop edits
as a separate release ahead of this work. Publish all required packages before
exposing the installer mode in a release ISO.

The work is complete when a clean network install obtains the new signed kernel
from `devario-core`, boots successfully under BIOS and UEFI, retains working
updates through the selected current Shelly release, starts the
`devario-desktop` Aqueous/Pearl session, passes the existing edition and trust
boundaries, and has a recorded, reproducible source/package trail. Offline
installation and recovery must also pass before replacing the current release.
