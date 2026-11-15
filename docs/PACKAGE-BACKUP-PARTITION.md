# Devario package backup partition

Status: proposed design, not implemented

Devario stores package-level restore points on a dedicated GPT partition so a
system can be returned to a recent known-good package state even when the
network repositories, the AUR service, or the running system are unavailable.
Each restore point pairs a `shelly backup --export` manifest with a
version-pinned snapshot of the exact installed package archives and their
detached signatures. The system retains exactly three restore points.

This feature complements the boot-tier recovery in `devario-boot`
(`/boot/devario-recovery` and the systemd-boot "previous kernel" entry). It
covers package state only; it does not store home data or local configuration
edits. The pacfiles workflow (`shelly utility --pacfiles`) remains the
configuration path.

## Preconditions verified against Shelly 3.2.0

- `shelly backup --export --name <name> --directory <dir>` writes a
  version-less TOML manifest (`standard`, `aur`, `flatpak` arrays of
  explicitly installed names) and runs as the invoking user.
  `--import` reinstalls the latest versions of the listed names and requires
  network access.
- `shelly install standard` accepts local archive paths. With
  `LocalFileSigLevel = Optional`, a present `.sig` is verified against the
  keyring.
- `shelly repo-db add` regenerates repository databases from archives and
  embeds existing `.sig` signatures; `shelly repo-db verify` validates
  database signatures against the keyring.
- The installed set can be mapped to cache archives with
  `shelly list standard --show-hidden --json` (Name, Version) plus
  `/var/lib/shelly/local/*/desc` (ARCH). Cache is `/var/cache/shelly/pkg`;
  AUR-built archives and signatures live in the invoking user's
  `~/.cache/Shelly`.
- Calamares 3.4.2 supports recipe-driven GPT partition layouts.

## Upstream dependency

Retention on the backup partition is authoritative only if the package cache
stops cleaning itself. Shelly 3.2.0's `DisableCacheClean` applies solely to
aggregate upgrades (`upgrade all`); standalone `shelly upgrade standard` —
the command `update-target-packages` runs inside the installation target —
still reaches the cache-clean path, whose prompt defaults to acceptance.

The Devario Shelly build therefore carries interim patches (see the upstream
proposal accompanying this design):

1. `disableCacheClean()` honors the setting for every upgrade path;
2. the shipped default is `DisableCacheClean = true`;
3. the affected upstream tests are updated;
4. the UI cache-clean action is gated in the Devario build.

Until these land, the first snapshot after installation is not guaranteed to
contain the installer-era archives.

## Partition

- One GPT partition with a Devario-specific type GUID and PARTLABEL
  `DevarioBackup`, ext4, created at install time for the erase and
  use-free-space choices. Shrink and side-by-side choices initially omit it and
  the feature degrades to a plain directory on the root filesystem.
- Sizing targets three full package closures plus headroom (not a disk
  percentage). Suggested floor: 20 GiB.
- Not referenced in `/etc/fstab`. The `devario-backup` package installs
  `.mount`/`.automount` units selected by PARTUUID so a missing disk never
  blocks boot and the live image mounts it identically.
- Contents are publicly signed artifacts plus names; no secret material is
  stored, so the partition does not require its own LUKS volume regardless of
  the root encryption choice.

## Restore point layout

Each restore point is a self-contained directory so pruning after publication
is trivially correct:

```
DevarioBackup/
├── points/<stamp>/
│   ├── manifest.toml          # shelly backup --export output
│   ├── index.json             # pkg → version → file → sha256, sig presence,
│   │                          # keyring epoch, source (repo/aur)
│   ├── snapshot.db.tar.zst    # shelly repo-db add over the exact versions
│   └── *.pkg.tar.zst (+ *.sig)
├── current -> points/<stamp>  # flipped by atomic rename
└── staging/                   # in-progress point, never a restore point
```

Hardlink deduplication across points is a later optimization, not part of the
first design.

## `devario-backup` package

A new recipe under `packages/` providing:

- `/usr/lib/devario/backup-export`
  1. Runs `shelly backup --export` into the point directory (export runs as
     the invoking user; the systemd path runs as root).
  2. Enumerates installed name-version-arch and copies the matching archives
     and `.sig` files from `/var/cache/shelly/pkg` and the user AUR cache.
  3. Runs `shelly repo-db add` for the snapshot database.
  4. Writes `index.json` and fails closed with a retained report when an
     archive or signature is missing. `shelly purify` and UI cache actions
     remain explicit user overrides; the report names what they removed.
  5. Publishes atomically: staging directory → rename into `points/` → flip
     `current`.
- `/usr/lib/devario/backup-restore`
  - online mode: `shelly backup --import` against the selected point;
  - offline mode: installs the explicit names from the point through a
    generated `file://` repository configuration using the system keyring,
    then repairs install reasons with `shelly mark dependency` for packages
    not named in the manifest.
- Retention engine:
  - At most three complete published points; a point in `staging/` does not
    count. Pruning deletes the oldest only after the new point is published
    and verified. Publication failure keeps all existing points. The engine
    never deletes a point to free space for a new one.
  - No-op coalescing: if the installed set equals an existing point, no new
    point is created, so a restore or a metadata-only transaction does not
    consume a slot.
  - Cache steward: after successful publication, prunes
    `/var/cache/shelly/pkg` to the union of installed versions and versions
    referenced by the retained points. Pruning never runs before publication.
    This bounds cache growth now that Shelly's own cleanup is disabled.
- Trigger: a `PostTransaction` hook installed under
  `/usr/share/rlpm/hooks/` (style of `95-devario-boot.hook`) that
  `systemd-run`s a debounced service, plus a fallback systemd timer.

## Installer integration

- `iso/airootfs/etc/calamares/modules/partition.conf` gains recipe/schema
  files (Calamares 3.4.2) that add the `DevarioBackup` partition to the erase
  and use-free-space choices. The LUKS interaction requires a test pass.
- A new `shellprocess@first_snapshot` instance runs after
  `shellprocess@update_target` in the `settings.conf` exec sequence. It
  follows the `update-target-packages` pattern: chroot into the target with an
  isolated environment, mount the backup partition, create restore point one.
  With the managed-cache patch, the installer's post-install upgrade retains
  both the image-era archives and the signed replacements, which supply the
  signatures for the locally built ISO packages.
- A `shellprocess@restore_from_backup` sequence variant restores offline
  during a fresh installation when a backup partition is detected.

## Live image restore

Boot the Devario image, run `/usr/lib/devario/restore-from-backup`
(desktop shortcut in the live session): it locates the partition by PARTLABEL,
mounts the target root and the backup partition, chroots, initializes the
target keyring, and delegates to `backup-restore`. The helper is listed in
`iso/profile.json` permissions and provided by `devario-backup`.

## Security and policy

- Signatures verify against `/etc/shelly.d/gnupg` in every restore path;
  unsigned local archives are reported and accepted only when the index
  records a deliberately unsigned origin (image build inputs before their
  first signed replacement).
- Restoring an older point is a downgrade and can reintroduce fixed
  vulnerabilities. Restore points are a recovery mechanism, not a routine
  downgrade channel; the restore prompt states this.
- The partition stores only signed public artifacts and package names.

## Test plan

- `tests/`: snapshot publish/prune/crash-resume cases using the failure
  injection pattern of `test-dracut-boot.sh`; exactly-three retention with
  coalescing; offline restore against a fixture `file://` repository;
  missing-archive fail-closed reporting.
- Extend `scripts/validate.sh` to assert the Calamares recipe renders the
  backup partition and that mount units carry nofail-equivalent semantics.
- Installer manual test: fresh install creates point one; post-install upgrade
  adds point two; oldest pruned only after point two verifies.

## Open verification items

1. `OperationContext.ask` behavior under `--no-confirm` with closed stdin
   (documents today's installer cache-clean behavior).
2. RLPM `SigLevel` inheritance for `file://` repositories (the
   `iso/shelly.build.conf` comment about `Never`) before pinning the restore
   repository configuration.
3. Fully offline install from a snapshot with unsynchronized remote databases.
4. Calamares recipe × LUKS matrix and shrink-choice fallback behavior.
5. Interrupted steward prune: retained points must never lose referenced
   cache entries.
