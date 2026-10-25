# Devario system integration

This package owns `devario-gpu-run`, GPU setup and hotplug services, the
graphics-session helper, greeter systemd drop-ins, the installed greeter
template, eGPU module settings, and UWSM environment defaults. `files.tsv`
lists every installed path and mode. The ISO installs these files from the
package; it must not carry competing copies in `iso/airootfs`.

`devario-desktop` in Aqueous continues to own desktop dependencies and
`/etc/xdg/aqueous/session.toml`. It requires this package starting with
1.0.5-2. The live ISO's `late-airootfs` greeter overrides remain intentional:
Calamares restores the packaged installed greeter template on the target.
Driver selection and optional NVIDIA installation policy are unchanged.

## Rendering preference

Release 1-4 reads `/etc/devario/gpu-policy.json` for both the greeter and the
desktop. The default `{"render_preference":"chassis"}` prefers integrated
graphics on portable, laptop, notebook, tablet, convertible and detachable
chassis, and dedicated graphics on recognized desktop chassis. Virtual machines,
missing DMI data and unknown chassis retain Aqueous's automatic selection.
This does not rely on GPU vendor, card numbering, battery presence or dock state.

Set `render_preference` to `auto`, `integrated` or `discrete` to override chassis
detection for both sessions. The configuration is a package backup file, so
upgrades preserve local changes. An explicit `AQUEOUS_RENDER_GPU_PREFERENCE`
environment value takes precedence over the file; `auto` disables the chassis
preference. Invalid or unreadable configuration safely uses `auto` and logs why.

Requires an Aqueous source release containing the rendering-preference support.
The compositor ranks Vulkan devices by their reported type, tries other hardware
if the preferred GPU is absent or fails initialization, and retains explicit
`WLR_RENDER_DRM_DEVICE` restrictions. Application policy remains separately
controlled by `AQUEOUS_GPU_POLICY=follow|inherit`, with `follow` using the actual
successful renderer. `devario-gpu-run` still selects another GPU per application.

Neither helper nor compositor automatically sets `WLR_DRM_DEVICES`: doing so
would restrict display discovery and disable wlroots GPU hotplug monitoring.
Explicit user device lists remain supported. External monitors on another GPU
remain eligible, and attaching a GPU does not migrate the running compositor.
Start a new session to reevaluate rendering preferences. Inspect the greeter or
user compositor journal for `graphics-session`, `Vulkan render preference`,
candidate attempts and `gpu-selection` identity messages. Physical hybrid and
desktop testing is still required before publishing a release.

## Build and release

1. Deploy Shelly CLI 3.1.9 or later with `shelly_migrate` support and the RLPM backend.
2. Build with that Shelly, sign, and publish `devario-system-integration` 1-4 in `devario-core`.
3. Build a new Aqueous source release through its normal packaging workflow and
   publish all six desktop outputs together. The older v1.0.5 tag predates the GPU
   preference implementation; advance the existing recipes to the new release.
4. Rebuild the ISO with the new integration package in its staged repository.

From the OS checkout, review and build with Shelly:

```sh
shelly build --review-only --json packages/devario-system-integration/PKGBUILD
shelly build --isolated packages/devario-system-integration/PKGBUILD
```

The alternative recipe in `devario-custom-packagbuilds/devario-installer/`
must be kept synchronized. The OS build scripts include this package too.

## Existing installations: one-time adoption

Release 1-3 declares `shelly_migrate` entries for every exact destination in
`files.tsv`, with `from: unowned` and `optional: true`. During installation,
Shelly/RLPM adopts existing unowned files in place, preserving their contents,
permissions and ownership attributes. Missing paths receive the packaged files
normally, so clean installations still work. The three UWSM environment files
also retain the package's backup policy. The declarations are included in
`.SRCINFO` and become `shelly.migration.v1` metadata in the built archive.

Update Shelly first, then start a new transaction for integration; upgrading
Shelly as a dependency cannot update the already-running package manager.
With the supporting Shelly CLI and RLPM backend active, install the published
integration and desktop packages normally:

```sh
sudo shelly install standard devario-system-integration devario-desktop
```

Review the adoption preview before confirming. This release targets unowned
ISO files only. A path owned by another package, including
`devario-aqueous-desktop`, is not an unowned file: the declaration fails rather
than silently taking it over. `optional` permits absent paths, not ownership
mismatches. Existing files already owned by `devario-system-integration` skip
unowned adoption and follow normal upgrade and backup rules.

Adoption preserves old helpers as well as configuration files on that first
transaction. Subsequent upgrades or reinstalls apply the current packaged
helpers normally; UWSM configuration changes still follow the backup policy.
Do not use a blanket overwrite to bypass a failed ownership check.

The source-only `migrate-overlay.py` is retained for historical recipes that
predate package-declared migration. It removes unowned files before installing
replacement bytes, so it is not the in-place preservation workflow for 1-3.
The current workflow does not require running that helper or an install hook
to resolve file ownership.

After adoption, future integration releases arrive through
`sudo shelly upgrade standard`. Bump this recipe's release and regenerate
checksums/`.SRCINFO` whenever its files change. UWSM environment files are
marked as backups so later upgrades preserve local edits through `.pacnew`.
Installation enables GPU hotplug for the next boot without restarting the
active greeter or compositor.
