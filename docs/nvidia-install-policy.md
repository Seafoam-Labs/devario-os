# NVIDIA install policy (Calamares, Shelly/RLPM)

This policy applies to the **installed target**. The live ISO deliberately
keeps `nvidia-open-dkms` and `nvidia-utils` in `iso/packages.x86_64`, so
NVIDIA-equipped computers can boot and run the graphical installer.

## On machines without an NVIDIA display controller

* The existing PCI detector is used. A detector failure aborts the install;
  it is **not** interpreted as absence of a GPU.
* The live-image NVIDIA payload preflight is skipped.
* After `unpackfs`, the target-only Calamares NVIDIA step resets
  `NVIDIA_EARLY_KMS` to `false` and removes installed `nvidia-open-dkms`
  and `nvidia-utils` through `shelly remove standard ... --no-cascade --no-confirm`
  with the native RLPM backend explicitly configured. `--no-cascade`
  prevents cascade removal of orphan dependencies (including DKMS) and avoids
  the CLI's default `-Rns`-equivalent removal of modified configurations.
* Only those two packages are removal targets. `dkms`, kernel headers, shared
  firmware and other packages are not explicitly removed; RLPM will reject
  the operation if another installed package requires an NVIDIA component.
* The later `--configure-updated` phase is idempotent: it detects no NVIDIA
  packages, skips NVIDIA DKMS checks and leaves the boot update to the existing
  system update pipeline.

If an eGPU is connected **later**, the user must explicitly install a
compatible NVIDIA driver and configure early KMS as appropriate. This release
no longer builds driver modules for absent/future eGPUs.

## On machines with a supported NVIDIA controller

The existing checks for GPU support, source/firmware presence, matching
kernel headers, DKMS module versions and early KMS remain in effect.
Unsupported NVIDIA GPUs still fail the install with an explicit error; this
change does not introduce automatic Nouveau fallback.

## Required release/build ordering

Use the published `devario-desktop` from Aqueous. Its dependency closure must
allow NVIDIA packages to be removed on non-NVIDIA targets; RLPM must reject
removal if any installed package still requires them. The ISO must continue
to explicitly include `nvidia-open-dkms` and `nvidia-utils` in
`iso/packages.x86_64`. GPU and greeter configuration comes from `devario-system-integration`.
Publish it before the desktop release that depends on it; existing ISO installs
need the [one-time adoption](../packages/devario-system-integration/README.md#existing-installations-one-time-adoption).

This patch does **not** change Dracut boot-image generation. The existing
`devario-boot` hooks and `boot-update` remain responsible for that step.

## Validation before merge

1. Run `python3 tests/test-configure-target-nvidia.py && python3 tests/test-update-target-packages.py`.
2. Build the desktop metapackage and a fresh live ISO.
3. In a VM without NVIDIA, install from the ISO. Confirm both NVIDIA packages
   are absent from the **target** via `shelly list standard --show-hidden --json`,
   and that `NVIDIA_EARLY_KMS=false`; check that kernel updates don't trigger
   NVIDIA DKMS rebuilds.
4. On real supported NVIDIA hardware (or PCI passthrough), test preflight,
   DKMS, initramfs and graphics. Unsupported devices must produce a clear error.
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
