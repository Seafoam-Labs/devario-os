<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

**Calamares NVIDIA detection, driver provisioning, and early KMS plan**

Status: offline installer implementation and focused automated tests completed.
Full image/hardware acceptance remains pending. Repository inspected 2026-09-28.
Driver version selected by the user: **615.71.09**.

Implementation uses a checked-in PCI ID table extracted from the official
615.71.09 open-module README. Its source URL and SHA-256 are recorded in
`iso/airootfs/usr/share/devario/nvidia-supported-gpus.json`; regenerate it with
`scripts/update-nvidia-supported-gpus.py --version VERSION README.md OUTPUT`.
When changing driver versions, update the desktop package's two exact NVIDIA
dependencies, regenerate the table from that release, and update the tests.
The installer checks both GSP and ucodes firmware shipped with 615.71.09.

The existing offline path copies drivers from the image and builds missing
target modules. Network transactions remain part of the separate network-install
plan because that installation mode does not exist yet. Automated coverage is
in `tests/test-configure-target-nvidia.py`, `tests/test-gpu-driver-setup.sh`, and
`tests/test-dracut-boot.sh`. Full `scripts/validate.sh` currently stops at the
pre-existing missing `packages/linux-cachyos-lts/{PKGBUILD,config,README.md}`;
the selected standalone kernel migration must resolve that release prerequisite.

Make Calamares detect supported NVIDIA display hardware, ensure the installed
system has compatible drivers and kernel modules, and set
`NVIDIA_EARLY_KMS="true"` in the target's `/etc/devario-dracut.conf` before
generating its boot images. Keep the packaged default disabled so installation
hardware, rather than the ISO build host, determines this setting.

**Verified starting point before implementation**

- `iso/airootfs/etc/calamares/settings.conf` runs `unpackfs`, target preparation,
  and then `shellprocess@limine`. The latter calls
  `/usr/lib/devario/boot-update --install` inside the target.
- The ISO and `devario-aqueous-desktop` already include `nvidia-open-dkms`,
  `nvidia-utils`, and `linux-cachyos-lts-headers`. Offline installation copies
  these packages; Calamares currently performs no package transaction.
- `packages/devario-aqueous-desktop/gpu-driver-setup --detect` already matches
  NVIDIA PCI vendor `0x10de` and display class `0x03*`, including secondary
  GPUs while excluding HDMI audio. Its boot-time setup is separate from
  installer provisioning and does not prove target-kernel compatibility.
- `packages/devario-dracut/dracut-install` reads the requested configuration
  and adds NVIDIA modules, but its ALPM hook is masked by `devario-boot`.
  The active `packages/devario-boot/initramfs-update` neither reads that flag
  nor includes NVIDIA modules explicitly. It uses an empty dracut configuration
  directory, so adding an `/etc/dracut.conf.d/` file alone also cannot fix this.
- The active boot path generates normal and fallback initramfs images, disables
  UKI generation, and publishes images only after successful inspection.
- `devario-boot/PKGBUILD` still requires `devario-dracut=111`, while the local
  dracut recipe is version 112. Resolve this packaging mismatch before release.

**1. Define detection and compatibility**

Reuse or extract the existing read-only PCI detector instead of parsing
`lspci` descriptions or requiring `nvidia-smi` to work in the live session.
Distinguish no NVIDIA hardware from an unreadable/missing sysfs tree. Record
PCI addresses and device/subsystem IDs for diagnostics. Never load or unload
drivers from the installer helper: a chroot still shares the live kernel.

For the initial implementation, retain the existing Turing-and-newer support
policy. NVIDIA documents this requirement for its
[open kernel modules](https://github.com/NVIDIA/open-gpu-kernel-modules#compatible-gpus).
Vendor detection alone is insufficient: package a reviewed device support
table tied to the shipped driver release, including subsystem restrictions
where applicable. Treat unknown IDs, older devices, and mixed supported/unsupported
NVIDIA systems as unsupported for automatic setup. Report the device and reason
before partitioning rather than claiming driver support. Do not automatically
install legacy/AUR drivers or promise a Nouveau fallback; the current image
deliberately retains the `nvidia-utils` Nouveau blacklist.

Add a read-only Calamares `shellprocess@nvidia_preflight` job as the first
execution step, before `partition`, with `dontChroot: true`. Validate hardware
support and the required package payload there. Target preparation should
recheck detection using mounted sysfs; do not assume the live `/run` state is
available inside the target, whose `/run` is a separate tmpfs.

**2. Provision drivers for the installation mode**

Required components are `nvidia-open-dkms`, matching `nvidia-utils`, DKMS and
its build dependencies, required firmware, and headers matching each target
kernel that the installer will expose as a supported boot choice.

- Current offline mode: preserve the drivers in the ISO and copied target.
  Verify their installed inventory and versions; copying the prepared root is
  the installation mechanism. Missing packages are an invalid installation
  payload and must fail clearly without unexpectedly requiring a network.
- Planned network mode: add the NVIDIA packages conditionally to the resolved
  target manifest and install them through the Shelly transaction described in
  `docs/NET-INSTALL-KERNEL-PLAN.md`. Resolve and verify the signed package set
  before partitioning. Use the same repository snapshot for kernel, headers,
  driver modules, and userspace libraries. Do not introduce a pacman command
  or enable Calamares's generic packages module solely for this feature.

The initial offline change can retain driver packages on non-NVIDIA systems;
those systems must not have early KMS enabled by the installer. Truly conditional
package presence requires removing NVIDIA hard dependencies from the desktop
metapackage and separating live and target manifests. Coordinate that work with
the existing network-install/desktop migration and update package validation
accordingly; do not remove packages while the desktop still requires them.

Derive target kernel versions from the existing `kernel.sh` selection contract
and target module trees, never `uname -r`. Today the header package is
`linux-cachyos-lts-headers`; use `linux-devario-headers` once the planned kernel
migration lands. Check that the chosen DKMS release and its hooks work with
Shelly and the available compiler rather than assuming pacman is present.

**3. Configure the target after driver verification**

Add an installer helper at
`iso/airootfs/usr/lib/devario/configure-target-nvidia` and a corresponding
`modules/nvidia.conf` shellprocess instance. Place `shellprocess@nvidia` after
`networkcfg` and before `shellprocess@limine`, using `dontChroot: false` and a
DKMS-appropriate timeout, initially 1800 seconds.

For supported hardware, the helper should:

1. Verify the required installed packages and exact target kernel/header pairing.
2. Reuse valid installed DKMS modules or run `dkms autoinstall -k <target-version>`
   as needed; run `depmod` for that version. Do not rely on successful package
   installation alone, since hooks may report build failures separately.
3. Verify all four modules with target-version `modinfo`: `nvidia`,
   `nvidia_modeset`, `nvidia_uvm`, and `nvidia_drm`. Check driver/userspace version
   compatibility and retain useful DKMS failure logs.
4. Atomically update `/etc/devario-dracut.conf` to contain exactly one active
   `NVIDIA_EARLY_KMS="true"` assignment, preserving unrelated settings and
   comments. Handle the commented default, an existing assignment, duplicate
   assignments, and a missing file. Repeated execution must be idempotent.
5. Ensure persistent `nvidia_drm` modesetting through the installed driver's
   configuration or a small installer-owned modprobe configuration, and ensure
   this configuration is included in the generated image. Loading it only in
   the later greetd setup service does not establish early KMS.

With no NVIDIA GPU, leave the fresh target's flag disabled and skip NVIDIA DKMS
work. Any selected NVIDIA setup failure must stop Calamares before bootloader
installation. Only write the true flag after module verification succeeds.
Record hardware selection, package versions, target kernel, and configuration
result in the installation log.

Update comments in `packages/devario-dracut/devario-dracut.conf` to explain that
Calamares sets the installed copy automatically. Do not globally uncomment the
packaged default. Clarify that the Devario Limine workflow builds normal and
fallback images; UKI support in the legacy wrapper is a separate path.

**4. Make the active boot builder honor the flag**

Extend `packages/devario-boot/initramfs-update` to read the optional automation
configuration in installed mode, defaulting `NVIDIA_EARLY_KMS` to false. Scope
this change to NVIDIA behavior; do not inadvertently change fallback/UKI policy.
Provide an explicit configuration-path override for isolated tests.

When enabled, verify the four modules against the selected target kernel and
pass them to dracut for both normal and fallback images. Use `--force-drivers`
if early loading is required, and verify that behavior with the packaged dracut
version; the legacy wrapper's `--add-drivers` only guarantees inclusion.
Verify the modules, necessary firmware, and modesetting configuration with
`lsinitrd` before publishing either image. Missing modules with the flag enabled
must fail explicitly, preserving the previously working boot files.

Keep `boot-update --install` as the single final generation/bootloader step.
Do not call the pacman-dependent legacy `dracut-rebuild` from Calamares or unmask
its competing hook. Preserve the existing atomic staging, recovery copy, and
rule that Limine is updated only after successful image generation.

Ensure the same behavior applies to subsequent kernel, headers, and NVIDIA
updates through `95-devario-boot.hook`, after DKMS finishes. Audit firmware and
`nvidia-utils` triggers as well as the existing module/kernel triggers. Update
affected package releases, source checksums, and the dracut version dependency.

**5. Verification and acceptance**

- Extend `tests/test-gpu-driver-setup.sh` or add focused installer tests using
  fake sysfs for Intel/AMD-only, supported NVIDIA, hybrid graphics, multiple
  GPUs, NVIDIA audio-only, unsupported/unknown IDs, and unreadable sysfs.
- Test target configuration preservation and idempotence; missing headers,
  packages, or individual modules; DKMS failure; and differing live/target
  kernel versions. Confirm no target helper attempts to modprobe the live kernel.
- Extend `tests/test-dracut-boot.sh` for true/false/missing configuration,
  NVIDIA modules in both images, early-loading arguments, and preservation of
  old images when module validation or generation fails. Live image generation
  must remain independent of the installer's detected hardware.
- Update `scripts/validate.sh` to check module presence, job ordering, package
  contracts, checksums, and hook ownership. Run the focused tests and repository
  validation; report pre-existing failures separately.
- Perform an offline Calamares install in a non-NVIDIA VM and on supported
  NVIDIA hardware or a VM with GPU passthrough. Verify the installed config,
  both images, graphical login, `nvidia-smi`, and
  `/sys/module/nvidia_drm/parameters/modeset`. Check encrypted-root display
  behavior and a hybrid laptop. Reboot after a kernel/driver update to exercise
  the persistent hook path. Repeat for network mode when that mode exists.

Completion means supported NVIDIA installations boot with verified drivers and
early KMS, non-NVIDIA installations retain the disabled setting, and failures
cannot be presented as a successful NVIDIA installation. Implement in order:
active boot-builder support, detection/preflight and target helper, Calamares
wiring, packaging/docs, then image and hardware acceptance.
