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

## Build and release

1. Deploy Shelly CLI 3.1.9 or later with `shelly_migrate` support and the RLPM backend.
2. Build with that Shelly, sign, and publish `devario-system-integration` 1-3 in `devario-core`.
3. Publish all six Aqueous `aqueous-desktop` 1.0.5-2 outputs together.
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
