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

1. Build, sign, and publish `devario-system-integration` 1-1 in `devario-core`.
2. Publish all six Aqueous `aqueous-desktop` 1.0.5-2 outputs together.
3. Rebuild the ISO with the new integration package in its staged repository.

From the OS checkout, review and build with Shelly:

```sh
shelly build --review-only --json packages/devario-system-integration/PKGBUILD
shelly build --isolated packages/devario-system-integration/PKGBUILD
```

The alternative recipe in `devario-custom-packagbuilds/devario-installer/`
must be kept synchronized. The OS build scripts include this package too.

## Existing installations: one-time adoption

Publish both packages before running this migration. Run it from a complete,
reviewed copy of this recipe directory, preferably from a text console with
desktop applications closed. Do this **before** the first normal upgrade to
the new desktop dependency: unowned ISO files otherwise fail Shelly's file
conflict checks. An install hook cannot fix that because hooks run afterward.

From the OS checkout:

```sh
python3 packages/devario-system-integration/migrate-overlay.py
sudo python3 packages/devario-system-integration/migrate-overlay.py --apply
```

The first command only inspects. The second backs up each unowned file under
`/var/lib/devario/migrations/system-integration-*`, removes those exact files,
and runs `shelly install standard devario-system-integration devario-desktop`.
It never removes package-owned files itself. The package declares a conflict
and replacement for `devario-aqueous-desktop`; Shelly handles ownership from
that older package in the same transaction. Files belonging to any unrelated
package, symlinks, and incomplete package inventories stop the migration.

If installation fails or is cancelled, missing original files are restored.
Files already written by a partial package transaction are left in place;
the backup retains every original, including local edits. Review and merge
any local changes from that backup, then reboot. A power loss or forced kill
during the migration requires restoring missing files from the printed backup
directory before retrying. Do not run other package operations concurrently.

The helper supports Devario's standard `/var/lib/shelly` database and direct
`/etc/shelly.conf` configuration. Custom roots, databases, or Include directives
require a site-specific migration rather than guessing at file ownership.

After adoption, future integration releases arrive through
`sudo shelly upgrade standard`. Bump this recipe's release and regenerate
checksums/`.SRCINFO` whenever its files change. UWSM environment files are
marked as backups so later upgrades preserve local edits through `.pacnew`.
Installation enables GPU hotplug for the next boot without restarting the
active greeter or compositor.
