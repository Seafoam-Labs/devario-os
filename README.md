# Devario

**A modern, Shelly-first Linux desktop.**

Devario OS is the independently usable core of Devario Community. It is an
Arch Linux derivative with the
[Aqueous](https://github.com/Seafoam-Labs/Aqueous) Wayland desktop, the base
Calamares installer, and
[Shelly](https://www.seafoam-labs.org/shelly-alpm/) as its system package
manager.

This repository contains the complete Community image, package recipes, build
pipeline, tests, and public release boundary. It builds without an account,
management service, or external edition overlay. See the
[Devario OS architecture](docs/architecture.md) for component and trust
boundaries.

To try Devario on physical hardware, follow
[Create and Boot a Devario USB Drive](docs/Create-and-Boot-Devario-USB.md).

The installed system does not ship the `pacman` or `pacman-key` executables. It uses four Devario packages instead:

- `shelly` provides the package-management CLI and UI.
- `devario-alpm-runtime` provides `libalpm` and the runtime data that Shelly needs, without the Pacman CLI or its build
  tools.
- `devario-base` provides the base-system dependency set without depending on Arch's `base` package, which would pull
  Pacman back into the image.
- `devario-keyring` installs the public Devario repository keys consumed by Shelly's keyring commands.

## What is included

- Archiso profile with BIOS and UEFI boot support
- Aqueous compositor with the Noctalia shell and Devario desktop defaults
- greetd with Noctalia Greeter for installed logins and an automatic Aqueous
  `liveuser` session on the live image
- NetworkManager, PipeWire, Firefox, and common filesystem tools
- Devario-built CachyOS LTS kernel targeting baseline x86-64 hardware
- NVIDIA open-driver support with PCI detection before the graphical greeter
- Fastfetch on the first interactive shell in each terminal
- Base Calamares 3.4.2 built from Codeberg
- Devario-packaged `ckbcomp` for Calamares keyboard previews on clean Arch builders
- Offline installation by unpacking the tested live SquashFS
- Limine installation for BIOS and UEFI targets, with a FAT `/boot` shared by
  both firmware paths
- ext4 as the default filesystem, with Btrfs, XFS, and F2FS available
- Shelly-backed repository search, installation, removal, upgrades, and keyring initialization
- Persistent first-boot initialization of the Arch Linux and Devario signing keyrings

Calamares does not invoke a package manager during installation. Its `unpackfs` module copies the prepared live root
filesystem, and the remaining modules configure that copy for the target machine.

ISO construction verifies that every Devario-owned package is present exactly
once in the local repository before installing the live root. In particular,
both `linux-cachyos-lts` and `linux-cachyos-lts-headers` must have been built by
`build-packages-nspawn.sh`; the kernel recipe alone is not an installable
artifact. The patched Archiso transaction also compares its requested package
list with Shelly's installed inventory and refuses a partial root filesystem.

The live and installed filesystems include `nvidia-open-dkms`, `nvidia-utils`,
and the Devario kernel headers. A boot service detects NVIDIA PCI display
controllers through sysfs, loads `nvidia_drm` with modesetting before greetd,
and records `nvidia`, `partial`, `unavailable`, or `none` in
`/run/devario/gpu-driver`. The `nvidia-utils` Nouveau blacklist is intentionally
left intact, so this image supports Turing-and-newer NVIDIA hardware through
the open kernel module and does not fall back to Nouveau on older GPUs.

The live account declarations are added only after ISO package hooks finish.
They remain available for systemd to create `liveuser` in the writable live
session at boot, but the account is not materialized in the SquashFS copied by
Calamares. Target preparation also removes any legacy `liveuser` account as a
defense against images built before this separation was introduced.

Automatic partitioning creates a GPT disk with a 1 GiB FAT `/boot` and an
8 MiB BIOS boot partition, allowing the same installation to start through
Limine under UEFI or legacy BIOS. A manual layout must likewise provide a FAT
partition mounted at `/boot`; legacy BIOS on GPT additionally requires a BIOS
boot partition. The installer stops instead of writing an unbootable Limine
configuration when those requirements are not met.

## Package-management boundary

The Pacman and `pacman-key` executables are not invoked during package builds,
ISO construction, live use, installation, or installed-system operation:

| Environment | Package-management components |
| --- | --- |
| Live and installed system | `shelly`, `devario-alpm-runtime`, `devario-base`, and `devario-keyring` |
| Package build host | Shelly synchronizes repositories and installs every declared build dependency. `makepkg` runs with `--nodeps`, automatic dependency probes disabled, and a strict Shelly inventory adapter; `repo-add` only writes repository metadata. |
| ISO build host | Bundled Archiso v89 orchestration patched so synchronization, target installation, and package inventory all run through the repository's Shelly binary. |

The vendor patch also converts Archiso's stock CI package setup and releng
keyring service to Shelly. Those upstream paths are not used by Devario's staged
profile, but keeping them Shelly-only prevents a dormant Pacman call from
remaining in the patched source tree.

`makepkg` remains the package archive builder and `repo-add` remains the
repository database writer because Shelly does not replace those formats or
construction tools. Every package-manager hook exposed to makepkg points to
`scripts/makepkg-shelly-adapter.sh`, which accepts only makepkg's read-only
`-Qi` inventory request, answers it through Shelly, and rejects all other
operations. The build script forbids dependency, removal, and install modes
that could bypass that adapter.

Shelly owns its runtime configuration and mutable package state:

- `/etc/shelly.conf`
- `/etc/shelly.d/hooks` and `/etc/shelly.d/gnupg`
- `/var/lib/shelly` and `/var/cache/shelly/pkg`

Some historical names remain only at upstream Arch compatibility boundaries:

- `/etc/pacman.d/mirrorlist`
- `/usr/share/pacman/keyrings`, where Arch and Devario distribute public trust roots
- Arch package archives, repository databases, signatures, and ALPM hooks
- Archiso's `pacman_conf` profile setting

Their presence does not mean `/usr/bin/pacman` or `/usr/bin/pacman-key` is present. Devario build scripts, runtime
services, and installer configuration must never invoke either executable, `pacstrap`, or `pacman-conf`.

`devario-alpm-runtime` also advertises a versioned virtual `pacman` provider because `archlinux-keyring` currently
depends on that package name. It conflicts with and replaces the real package, but it does not contain either Pacman
executable. This compatibility metadata is checked separately from the image-content rule.

The packaged Shelly source is patched at build time because upstream 3.0.6 still delegates keyring and repository
operations and pacfile ownership lookup to Pacman programs. Devario routes keyring actions through `shelly-key` or
GnuPG, reads ownership information directly from `/var/lib/shelly`, defaults to `/etc/shelly.conf`, and supports
`SHELLY_ALPM_CONFIG` for isolated image roots. The package build and artifact validator enforce this boundary. Existing
installations are bridged during the package upgrade and materialized under the new paths by
`shelly-storage-migrate.service` at the following boot. Verified legacy data is retained under
`/var/lib/devario/shelly-path-migration/legacy`; `/usr/lib/devario/shelly-storage-migrate --rollback` can recreate
current compatibility state during the rollback window.

## Using Shelly

Run a full repository synchronization and system upgrade:

```sh
shelly upgrade standard
```

Install one or more repository packages:

```sh
shelly install standard package-name another-package
```

Install a local Arch package archive:

```sh
shelly install standard ./package-name.pkg.tar.zst
```

Search configured repositories and show exact package details:

```sh
shelly search standard package-name --available --detail
```

Remove a package:

```sh
shelly remove standard package-name
```

Initialize and populate a damaged or new keyring:

```sh
shelly keyring init
shelly keyring populate archlinux devario
```

Shelly requests elevation for privileged transaction steps. Run it as the invoking desktop user rather than wrapping the
whole command in `sudo`. Use full upgrades rather than synchronizing repositories and installing individual packages
into an otherwise stale system.

## Build prerequisites

Build on an up-to-date Arch Linux or Arch-derived x86-64 system. Once Shelly is available on the build host, install the
required Archiso and packaging tools through Shelly:

```sh
shelly install standard --upgrade archiso base-devel git limine
```

For virtual-machine testing, the QEMU helper installs `qemu-desktop` and
`edk2-ovmf` through Shelly and prepares host KVM access when available:

```sh
./scripts/setup-qemu.sh --install-only
```

The build host must already have a working Shelly installation. Use a verified
Seafoam Labs package or a previously built Devario Shelly package to establish
that bootstrap environment.

Use an official baseline Arch x86-64 builder for distributable artifacts.
Optimized derivative toolchains can stamp their startup objects with a higher
ISA requirement even when an individual recipe requests baseline compilation.

On a systemd host, the supplied nspawn wrapper downloads and verifies the
official Arch bootstrap filesystem, injects the locally trusted Shelly package,
installs all build inputs through Shelly, and builds as an unprivileged user.
It does not invoke the Pacman executable:

```sh
sudo ./scripts/build-packages-nspawn.sh
```

To create or update the persistent builder without starting a package build:

```sh
sudo ./scripts/build-packages-nspawn.sh --prepare-only
```

The default container root is `/var/lib/machines/devario-builder`. Override it
with `DEVARIO_NSPAWN_ROOT` when required. The container uses official baseline
userspace libraries but shares the host CPU, so package recipes must retain the
explicit x86-64, Rust, Go, and Zig baseline settings enforced by the wrapper.

Do not build packages as root. `build-packages.sh` asks Shelly to synchronize
and install the complete build dependency set, then runs makepkg only as the
regular build user. Build the ISO itself as root because image construction
mounts target API filesystems while Shelly processes package hooks and
scriptlets.

## Build

Initialize a local development signing key and export its public material into the keyring package. The ignored
`.devario-signing/` directory contains the secret key and must remain private:

```sh
./scripts/init-repository-key.sh
```

Build Calamares, its `ckbcomp` helper, Shelly, the ALPM runtime split, the
Devario base and keyring packages, the pinned baseline `linux-cachyos-lts`
kernel and headers, and the pinned Aqueous, Noctalia, Noctalia Greeter,
session, and desktop packages. If a local fingerprint exists, the script signs
every package and the repository database automatically:

```sh
./scripts/build-packages.sh
```

Core artifacts are written only to `repo/core/`; that directory is never
shared with managed-edition artifacts.

Pass package-directory names to rebuild only selected packages while retaining
the other existing repository artifacts. Kernel updates should be built in the
official baseline container so host ISA settings cannot leak into release
artifacts:

```sh
sudo ./scripts/build-packages-nspawn.sh linux-cachyos-lts
```

The kernel recipe pins the CachyOS release tarball and vendored configuration
with BLAKE2 checksums and unconditionally selects `generic_v1`. Updating it is a
maintainer operation documented in
`packages/linux-cachyos-lts/README.md`; installed systems receive the resulting
binary exclusively from the signed Devario repository.

Validate package, profile, Calamares, service, and Shelly/Pacman-boundary invariants:

```sh
./scripts/validate.sh
```

Community is the default edition. The build first copies the canonical
`archiso/` profile into a temporary directory, then applies the data-only
contract in `editions/community/`. An edition directory contains:

- `edition.conf` with validated display and ISO metadata
- `packages.add` and `packages.remove`, one package name per line
- `package-sources.conf`, with exactly one `package_name=arch|core|managed`
  origin for every `packages.add` entry and no extra mappings
- `replacements.allow`, listing every exact base-profile file it may replace
- optional `airootfs/` and `late-airootfs/` configuration overlays

An out-of-repository edition must also provide `base.lock` containing exactly
`devario_os_commit=<40-character-commit>`. Validation and builds reject a
mismatched or dirty core checkout, undeclared file collisions, stale
replacement allowances, unsafe symlinks, special files, executable overlay
content, ambiguous package origins, managed origins in Community, and removal
of required core packages. Edition-specific executable
code belongs in a package, where its ownership, modes, dependencies, and
provenance can be validated.

Validate an external edition explicitly:

```sh
./scripts/validate.sh --edition ../devario-managed-overlay
```

Build the ISO. The wrapper verifies and patches its bundled Archiso v89 source,
extracts the updated Shelly binary from the signed local repository, and uses
that binary for the isolated target transaction. Each build initializes and
populates a temporary Arch and Devario verification keyring in the work
directory, passes its absolute path to the transaction, and deletes it
afterward. The keyring stays outside `airootfs`, so its private bootstrap key
is never packaged into the ISO:

```sh
sudo ./scripts/build-iso.sh
```

Pass the same edition directory to either ISO builder when producing a derived
image:

```sh
sudo ./scripts/build-iso.sh --edition ../devario-managed-overlay
sudo ./scripts/build-iso-nspawn.sh --edition ../devario-managed-overlay
```

The nspawn wrapper mounts an external edition read-only at
`/devario-edition`; it never copies private overlay sources into the core
checkout.

The resulting image is written to `out/`, and intermediate Archiso state is stored in `work/`. Override either location
when needed:

```sh
sudo DEVARIO_OUTPUT_DIR=/path/to/out \
  DEVARIO_WORK_DIR=/path/to/work \
  ./scripts/build-iso.sh
```

To reuse the baseline nspawn environment for ISO construction, use the nspawn
wrapper. It prepares the container when necessary, installs the Archiso
toolchain through Shelly, grants the container only the additional mount and
device-node capabilities needed by Archiso, and calls the same ISO builder.
Its mutable Archiso work tree is created inside the container rather than on
the project bind mount, avoiding user-namespace overflow ownership on target
files. Only the completed output directory is host-bound:

```sh
sudo ./scripts/build-iso-nspawn.sh
```

The complete ISO-construction output is retained at
`out/devario-iso-build.log`. If construction fails, the wrapper also prints
the final 200 lines again so the relevant error remains visible after verbose
package output exceeds the terminal's retention buffer. Signature-validation
failures additionally retain `out/devario-gpgme.log` and
`out/devario-iso-failure-report.log` for exact GPGME and keyring diagnostics.

Set `DEVARIO_NSPAWN_WORK_DIR` to retain work at a specific absolute path inside
the container. The nspawn wrapper rejects `DEVARIO_WORK_DIR`, which remains an
option only for native `build-iso.sh` runs.

Release repository and output overrides are forwarded into the container. For
example:

```sh
sudo env \
  DEVARIO_CORE_REPO_URL=https://repo.seafoam-labs.org/devario-core/x86_64 \
  ./scripts/build-iso-nspawn.sh
```

## Repository signing and publication

With no `DEVARIO_REPO_URL`, the ISO builder embeds the development repository at `/opt/devario/repo` and configures the
installed system to use it with `Optional TrustAll`. That mode works offline but is not suitable for publication. The
temporary repository used only while constructing the image has `SigLevel = Never`, because the build host does not own
Devario's trust root; this does not become the installed configuration.

For a release, export the public half of an existing offline-controlled signing
key into a reviewed source commit. Release artifacts are produced only by the
fresh, one-shot controlled nspawn wrappers; a native script cannot claim
release mode. Supply immutable bootstrap/snapshot inputs, an external
invoking-user-owned mode-0700 signing home, and a fresh output directory:

```sh
DEVARIO_GNUPGHOME=/secure/devario-gnupg \
  DEVARIO_SIGNING_KEY=<fingerprint> \
  ./scripts/init-repository-key.sh

sudo env DEVARIO_RELEASE_BUILD=1 \
  DEVARIO_BOOTSTRAP_URL=https://archive.example.org/archlinux-bootstrap-2026.08.14.tar.zst \
  DEVARIO_ARCH_SNAPSHOT_URL=https://archive.archlinux.org/repos/2026/08/14/ \
  DEVARIO_NSPAWN_ROOT=/var/lib/machines/devario-core-release-2026.08.14 \
  DEVARIO_GNUPGHOME=/secure/devario-gnupg \
  DEVARIO_SIGNING_KEY=<fingerprint> \
  ./scripts/build-packages-nspawn.sh --output /release/2026.08.14/packages

sudo env DEVARIO_RELEASE_BUILD=1 \
  DEVARIO_BOOTSTRAP_URL=https://archive.example.org/archlinux-bootstrap-2026.08.14.tar.zst \
  DEVARIO_ARCH_SNAPSHOT_URL=https://archive.archlinux.org/repos/2026/08/14/ \
  DEVARIO_NSPAWN_ROOT=/var/lib/machines/devario-iso-release-2026.08.14 \
  DEVARIO_GNUPGHOME=/secure/devario-gnupg \
  DEVARIO_SIGNING_KEY=<fingerprint> \
  DEVARIO_CORE_REPO_DIR=/release/2026.08.14/packages/devario-core \
  DEVARIO_CORE_REPO_URL=https://packages.example.org/devario-core/x86_64 \
  DEVARIO_OUTPUT_DIR=/release/2026.08.14/image \
  ./scripts/build-iso-nspawn.sh --release-version 2026.08.14
```

The release version must match
`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`. It is bound in the signed input lock and
attestation, embedded in the image build-source record, and rendered into
`/etc/os-release`; candidate metadata cannot supply a different version later.
The closed output also retains `CORE-INPUT-LOCK.json`,
`CONTROLLED-BUILDER.json` and its signature, and
`BUILDER-ATTESTATION.json` and its signature.

Release-mode ISO construction rejects non-HTTPS repository URLs and unsigned
artifacts, then verifies every package and repository database against the
active production signer in the packaged rotation-safe public bundle. It
writes a runtime `/etc/shelly.conf` requiring signatures. Replace the example
URLs with the real immutable/repository endpoints.

Build managed packages through the core-controlled external-package interface;
the input root keeps core repository bytes and the two public trust bundles
physically distinct:

```sh
sudo env \
  DEVARIO_BOOTSTRAP_URL=https://archive.example.org/archlinux-bootstrap-2026.08.14.tar.zst \
  DEVARIO_ARCH_SNAPSHOT_URL=https://archive.archlinux.org/repos/2026/08/14/ \
  DEVARIO_NSPAWN_ROOT=/var/lib/machines/devario-managed-release-2026.08.14 \
  DEVARIO_GNUPGHOME=/secure/devario-managed-gnupg \
  DEVARIO_SIGNING_KEY=<managed-fingerprint> \
  ./scripts/build-packages-nspawn.sh --managed-build \
    --managed-overlay ../devario-managed-overlay \
    --managed-input-root /release/2026.08.14/managed-input \
    --output /release/2026.08.14/managed-packages
```

Before publishing a release:

1. Create a dedicated offline-controlled Devario package-signing key. Never commit its private material.
2. Sign every package archive and the repository database; `build-packages.sh` does this when `DEVARIO_SIGNING_KEY` is
   set or its configured signing home contains a fingerprint.
3. Distribute the exported public key through `devario-keyring`. The Shelly keyring service populates both `archlinux`
   and `devario`, and remains enabled so a freshly installed target initializes its own keyring.
4. Publish the repository over HTTPS at a stable URL available after installation.
5. Verify that the production Devario repository renders with `SigLevel = Required`, which requires signatures on both
   packages and databases; remove `TrustAll` and the development `file://` server.
6. Test a clean install, first-boot keyring initialization, metadata refresh, full upgrade, package install, and key
   rotation using only signed artifacts.

The signing keyring package must be updated before a signing-key transition. Release the old-key-signed trust update
first, then begin signing repository content with the new key.

## Test

Install any missing QEMU dependencies, create a persistent 64 GiB sparse test
disk, and boot the newest image in `out/` with UEFI firmware:

```sh
./scripts/setup-qemu.sh
```

The helper uses KVM acceleration when the current login has access to
`/dev/kvm`; otherwise it sets up `kvm` group membership when possible and uses
software emulation for the current run. Pass a particular image with `--iso`,
test legacy BIOS with `--bios`, or boot the installed disk without attaching
the ISO:

```sh
./scripts/setup-qemu.sh --iso /path/to/devario.iso
./scripts/setup-qemu.sh --bios
./scripts/setup-qemu.sh --disk-only
```

UEFI and BIOS use separate persistent disks below `out/qemu/`. If host OpenGL
causes a display error, rerun with `--no-gl`.

Before publishing an image, verify that:

1. The ISO boots in both BIOS and UEFI modes.
2. greetd automatically starts `liveuser` through UWSM in the Aqueous session,
   with Noctalia running as the shell.
3. The Noctalia application launcher lists Calamares, and `Super+I` opens it
   through Polkit.
4. Automatic and manual partitioning complete successfully.
5. The installed system boots through Limine without the ISO attached in both
   UEFI and legacy BIOS modes.
6. NetworkManager and greetd are enabled on the installed system.
7. Noctalia Greeter lists `Aqueous`, authenticates a user, and starts the
   packaged UWSM session.
8. `command -v shelly` succeeds, while `command -v pacman` and `command -v pacman-key` fail.
9. `ldd /usr/bin/shelly` resolves `libalpm` from `devario-alpm-runtime`.
10. Keyring initialization and a signed full system upgrade succeed.
11. Package install, local-package install, removal, provider resolution, and ALPM hooks work.
12. A kernel or Limine upgrade regenerates initramfs as applicable, refreshes
    `limine.conf` and the deployed Limine binaries, and leaves the system bootable.
    Verify that the active release contains `cachyos-lts` in `uname -r` and that
    both normal and fallback Limine entries use the matching artifact names.
13. On Turing-or-newer NVIDIA hardware, `/run/devario/gpu-driver` contains
    `nvidia`, `nvidia-smi` succeeds, and
    `/sys/module/nvidia_drm/parameters/modeset` contains `Y`. Also verify that a
    non-NVIDIA machine records `none` and still reaches Aqueous.
14. An `execve` trace of package and ISO construction contains Shelly calls and no Pacman, `pacman-key`, `pacman-conf`,
    or `pacstrap` process.

## Development limitations

- Development images deliberately trust their embedded repository. Public images must use release mode with a signed
  HTTPS repository.
- Devario maintainers must track CachyOS LTS security releases, rebuild and
  sign the pinned kernel promptly, and publish corresponding source materials.
- The current local development repository was built on a CachyOS x86-64-v4
  host. Aqueous itself is baseline, but the locally built C++ desktop packages
  and the pre-existing Calamares artifact inherit the host's v4 startup-object
  requirement. Rebuild all release artifacts on official baseline Arch before
  publishing a generally bootable x86-64 image.
- Shelly's optional AUR workflow still requires a makepkg-compatible build toolchain. That toolchain is intentionally
  absent from the default live and installed systems; the supported default runtime covers signed binary repositories
  and local package archives.
- The live image leaves Calamares installed on the target until removal is covered by automated installation tests.
- Secure Boot is not configured.
- Pre-Turing NVIDIA GPUs are unsupported because the image intentionally keeps
  the `nvidia-utils` Nouveau blacklist enabled.
- `libalpm` ABI changes require a coordinated rebuild and release of `devario-alpm-runtime` and Shelly.

## Repository layout

```text
archiso/                         Archiso profile and live filesystem overlay
archiso/shelly.runtime.conf      Installed-system Shelly configuration template
docs/                            High-level product and architecture documentation
packages/calamares/              Upstream Calamares package
packages/ckbcomp/                Calamares keyboard-layout compiler helper
packages/shelly/                 Shelly package adapted to the split ALPM runtime
packages/devario-alpm-runtime/   libalpm runtime without Pacman executables
packages/devario-base/           Base dependency set without Arch's base package
packages/devario-keyring/        Devario public package-signing keys
packages/linux-cachyos-lts/      Pinned, baseline CachyOS LTS kernel recipe
packages/aqueous/                Aqueous compositor, UWSM session, and Noctalia integration
packages/noctalia/               Pinned Noctalia shell package
packages/noctalia-greeter/       Pinned greetd-native Noctalia Greeter package
packages/devario-aqueous-desktop/ Complete desktop dependency set and target greetd template
repo/core/                       Generated core-only local binary repository
repo/managed/                    Reserved physical boundary for managed artifacts
scripts/                         Package, validation, and ISO build entry points
tools/devario-archiso/           Checksummed Archiso v89 source and Shelly bootstrap patch
```
