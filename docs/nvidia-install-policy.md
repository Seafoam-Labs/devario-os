# NVIDIA install policy (Calamares, Shelly/RLPM)

This policy applies to the **installed target**. The live ISO deliberately
keeps `nvidia-open-dkms` and `nvidia-utils` in `iso/packages.x86_64`, so
supported newer NVIDIA computers can use the open driver in the live session.
The ISO also carries the signed CachyOS-based NVIDIA 580 stack for offline
installation on Maxwell, Pascal and Volta hardware: `nvidia-580xx-dkms`,
`nvidia-580xx-utils`, `opencl-nvidia-580xx`, `lib32-nvidia-580xx-utils`, and
`lib32-opencl-nvidia-580xx`. The packaging baseline is 580.178.04 with epoch 1
to migrate existing Devario 580.196.07 installations through normal updates.
These mutually exclusive packages are cached, not installed in the live root.
Live graphics on older hardware still depend on the available firmware/display
fallback; this target policy does not switch the running live-session driver.

## On machines without an NVIDIA display controller

* The existing PCI detector is used. A detector failure aborts the install;
  it is **not** interpreted as absence of a GPU.
* The live-image NVIDIA payload preflight is skipped.
* After `unpackfs`, the target-only Calamares NVIDIA step resets
  `NVIDIA_EARLY_KMS` to `false` and removes installed packages from either
  NVIDIA branch through `shelly remove standard ... --no-cascade --no-confirm`
  with the native RLPM backend explicitly configured. `--no-cascade`
  prevents cascade removal of orphan dependencies (including DKMS) and avoids
  the CLI's default `-Rns`-equivalent removal of modified configurations.
* Only the current and 580 NVIDIA driver, graphics and OpenCL packages are
  removal targets, including either 580 DKMS variant. `dkms`, kernel headers, shared
  firmware and other packages are not explicitly removed; RLPM will reject
  the operation if another installed package requires an NVIDIA component.
* The later `--configure-updated` phase is idempotent: it detects no NVIDIA
  packages, skips NVIDIA DKMS checks and leaves the boot update to the existing
  system update pipeline.

If an eGPU is connected **later**, the user must explicitly install a
compatible NVIDIA driver and configure early KMS as appropriate. This release
no longer builds driver modules for absent/future eGPUs.

## On machines with a supported NVIDIA controller

The installer prefers the current open driver when its support table covers
every detected NVIDIA display controller. Otherwise it selects the proprietary
580 driver if its table covers all controllers, including a mixture of older
and newer GPUs. It rejects hardware combinations with no common supported
driver, and older GPUs that require a branch predating 580.

Before partitioning, preflight verifies the selected payload and matching
kernel headers. For 580, it checks the cached archives and signatures against
the build manifest; build staging validates the archived DKMS sources,
firmware and dependency-name coverage. After `unpackfs`, the target helper
disables early KMS, initializes package trust, removes the copied current driver
and any current NVIDIA OpenCL/multilib packages with dependency checks enabled,
and installs all five signed 580 archives through
Shelly/RLPM. No network or AUR build is needed. A failed transaction aborts the
installation. The live root is never modified by this transaction.

All five 580 packages must match the NVIDIA upstream version, including the
32-bit libraries and OpenCL implementations. Missing packages, mismatched
repository/archive metadata, missing libraries or signatures fail staging.
Shared `lib32-gcc-libs`, `lib32-libglvnd`, `lib32-zlib`, and `ocl-icd` (the OpenCL loader)
dependencies are included in the live package closure so installation is offline.

Both branches require matching driver/library versions, sources, firmware,
kernel headers and DKMS modules before enabling early KMS. The 580 branch
expects the proprietary module license and its two GSP firmware files; the
current open branch retains its existing checks. Later updates use the support
table shipped by the installed driver: the open DKMS README, or the 580
utilities' `supported-gpus.json`, with the version checked against
`supportedchips.html`. NVIDIA's feature flags exclude older legacy branches
and GPUs requiring open modules, such as Blackwell. Branch-specific package names
keep subsequent upgrades on 580. Target update validation also supports a
manually selected `nvidia-580xx-open-dkms`: it uses that package's README GPU
table and requires the open module license. The installer still selects the
current open driver or proprietary 580; it does not cache or select open 580.

## Required release/build ordering

Use the published `devario-desktop` from Aqueous. Its dependency closure must
allow NVIDIA packages to be removed on non-NVIDIA targets; RLPM must reject
removal if any installed package still requires them. The ISO must continue
to explicitly include `nvidia-open-dkms` and `nvidia-utils` in
`iso/packages.x86_64`. GPU and greeter configuration comes from `devario-system-integration`.
Publish it before the desktop release that depends on it; existing ISO installs
need the [one-time adoption](../packages/devario-system-integration/README.md#existing-installations-one-time-adoption).

Run `scripts/stage-iso-repositories.py` to include the signed 580 packages from
the configured public repositories in the authenticated build snapshot.
Publish both `nvidia-580xx-utils` and `lib32-nvidia-580xx-utils` split recipes
from the packaging workspace first (epoch 1, version 580.178.04 or a coordinated
later 580 release). The Devario adaptation includes the required upstream GPU
feature metadata; an unmodified CachyOS binary is not a substitute.
`repository-packages.x86_64` lists all five offline packages, including native
and 32-bit OpenCL, plus the shared multilib dependencies for repository builds.
`scripts/build-iso.sh` runs `stage-nvidia-payload.py` after repository verification.
It generates `/usr/share/devario/nvidia-supported-gpus.json` from the README in
the exact `nvidia-open-dkms` archive selected by the repository database, checking
that its version matches `nvidia-utils` and the README. This replaces the
checked-in reference table, so package updates cannot leave an obsolete version
requirement in the ISO. Missing or inconsistent metadata fails the build;
installer version and hardware checks remain strict.

The same staging step generates `/usr/share/devario/nvidia-580xx/manifest.json`
and caches all five signed archives in the staged profile. Missing packages, signatures, sources, firmware,
version mismatches or missing offline dependencies fail the build. Additional
shared dependencies must be included in `iso/packages.x86_64` if future 580
packages require them. Do not add the conflicting driver packages to that list.

The existing `devario-boot` hooks and `boot-update` generate and validate both
boot images; the package triggers now include the 580 package names.

## Validation before merge

1. Run the NVIDIA configuration, payload staging, repository staging and target
   update tests (`tests/test-configure-target-nvidia.py`,
   `tests/test-stage-nvidia-payload.py`, `tests/test-stage-iso-repositories.py`,
   `tests/test-update-target-packages.py`) using `scripts/with-validation-env.sh`.
2. Build the desktop metapackage and a fresh live ISO.
3. In a VM without NVIDIA, install from the ISO. Confirm both NVIDIA packages
   are absent from the **target** via `shelly list standard --show-hidden --json`,
   and that `NVIDIA_EARLY_KMS=false`; check that kernel updates don't trigger
   NVIDIA DKMS rebuilds.
4. On both current open-driver hardware and Maxwell/Pascal/Volta hardware (or
   PCI passthrough), test offline preflight, installation, DKMS, initramfs,
   graphics and a subsequent online update. Test mixed GPUs supported by 580
   and a combination with no common supported branch. Unsupported devices must
   produce a clear error. Run `tests/test-nvidia-preflight-image.py IMAGE_ROOT`
   against the rebuilt image to exercise real Shelly and the cached payload.
5. Test an intentional RLPM removal failure: Calamares must stop rather than
   report a successful install.
6. Install from an ISO built with an *outdated* hard-dependency desktop package:
   Calamares must show the explicit metapackage/ISO rebuild error.

Integration with a real Calamares environment and RLPM transaction is **not**
covered by unit tests and must be tested before shipping the image.

**Known eGPU UX limitation:** After a non-NVIDIA installation, a newly
connected NVIDIA eGPU currently yields an `unavailable` state until drivers
are explicitly installed. `gpu-driver-setup` still reports a generic module
load error; a dedicated hotplug diagnostic is a separate follow-up.
