# Devario

**A modern, Shelly-first Linux desktop.**

Devario OS is an independent Linux distribution with Arch Linux package
ecosystem compatibility, and the independently usable core of Devario Community.
It features the
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

## Independent distribution, Arch-compatible ecosystem

Devario maintains its own system integration, signed package repositories,
kernel and boot lifecycle, desktop defaults, installer, and release validation.
The live and installed systems use Devario repositories by default; Arch
repositories and mirrorlists are not included in the default configuration.
Shelly manages the system through its native RLPM backend.

Compatibility with Arch is at the package ecosystem level: Devario retains
Arch-compatible package archives, repository metadata, PKGBUILD recipes, and
ALPM hooks. Shelly's native `shelly build` command builds PKGBUILD recipes into
installable package archives, and Shelly handles package transactions. This
allows Devario to reuse Arch ecosystem tooling and packaging work while
maintaining its own operating-system policies and release process.

Package-format compatibility does not guarantee that every Arch or AUR package
will work unchanged: dependencies, library versions, hardware requirements,
and assumptions about system tools still need to match Devario. Shelly's
optional AUR workflow uses Shelly's native builder and requires the recipe's
build tools and dependencies. The supported default
package workflow uses signed Devario binary repositories and local package
archives.

The installed system uses Shelly for package transactions and signing-key
management, supplied by these Devario packages:

- `shelly` and `shelly-cli` from `devario-core` provide the UI, CLI, and native RLPM backend.
- `devario-base` provides the base-system dependency set, Shelly repository configuration, and native RLPM storage directories.
- `devario-keyring` installs the public Devario repository keys consumed by Shelly's keyring commands.

## What is included

- Devario ISO profile with BIOS and UEFI boot support
- Aqueous compositor with the Pearl shell and Devario desktop defaults
- greetd with Pearl Greeter for installed logins and an automatic Aqueous
  `liveuser` session on the live image
- Fish as the interactive login shell for the live user and new user accounts
- NetworkManager, PipeWire, Firefox, and common filesystem tools
- Matugen for generating theme colors
- Diagnostic tools: strace, ripgrep, vulkan-tools, mesa-utils, wayland-utils,
  usbutils, lsof, nvme-cli, and OpenBSD netcat (`nc` and `netcat`)
- Seafoam Labs Devario kernel targeting x86-64-v3 hardware
- NVIDIA open-driver support with PCI detection before the graphical greeter
- Fastfetch on the first interactive shell in each terminal
- Calamares 3.4.2 built from Codeberg with [Pearl appearance](packages/calamares/README.md), including dark/light palettes and reduced-motion support
- Devario-packaged `ckbcomp` for Calamares keyboard previews
- Calamares keyboard selections carried into `/etc/xdg/aqueous/input.toml`
  after installation updates, including XKB variants and options; personal
  Aqueous input configurations retain precedence over the system default
- Offline installation by unpacking the tested live SquashFS
- systemd-boot installation for 64-bit UEFI targets, with a FAT EFI partition at `/boot`
- Btrfs as the default filesystem, with Btrfs, XFS, and F2FS available
- Shelly-backed repository search, installation, removal, upgrades, and keyring initialization
- Persistent first-boot initialization of the Devario signing keyring

`devario-base` also installs **Devario Report** in the application menu and the
`devario-report.sh` command. It collects hardware details, scheduler information,
kernel messages, current and previous boot warnings, and the Shelly package
inventory. It redacts local usernames, home paths, hostname, IP/MAC addresses,
and email addresses before offering a public upload to
[paste.c-net.org](https://paste.c-net.org/). Review the saved report before sharing;
redaction cannot guarantee removal of every private detail.

Run `devario-report.sh --no-upload` to collect locally, or `devario-report.sh
--upload` to publish without the prompt. The command writes `devario-report.log`
in the current directory (`LOG_FILENAME` can override it) and keeps the previous
report as `.old`. The menu launcher opens Ghostty, saves reports under
`${XDG_STATE_HOME:-~/.local/state}/devario/reports`, and keeps the window open
so the link can be copied. Administrator authentication is requested for system
logs. Reports remain available locally if the paste service fails.

Pearl runs inside the packaged Aqueous UWSM session. Devario sets
`/etc/xdg/aqueous/session.toml` to select Pearl; an existing user selection
takes precedence. Pearl Greeter uses its own `pearl-greeter.service`, the
`pearl-greeter` account, and VT7. The live autologin configuration is applied
in `iso/late-airootfs` after package hooks; installation restores the packaged
login template without live autologin.

GNOME Keyring and Seahorse are included in the core ISO and installed desktop.
The late ISO overlay starts the packaged GNOME Keyring user service and its
required socket with the user manager. The greetd PAM hooks unlock the login keyring during
password login, following the [GNOME PAM integration](https://wiki.gnome.org/Projects/GnomeKeyring/Pam).
These settings survive Calamares installation; rebuild the ISO to deliver them.
An existing keyring must use the login password for automatic unlocking.

Aqueous defaults to floating windows (`stacking` in its configuration) for the
live session and new installed users. The late ISO overlay supplies
`/etc/xdg/aqueous/layout.toml` as the system fallback and seeds an editable
`~/.config/aqueous/layout.toml` through `/etc/skel`. Rebuild the ISO to include
these defaults; users can change their layout through Pearl settings.

Desktop icons are enabled for the live session and new installed users through
the Pearl preferences in `/etc/skel`. UWSM initializes localized XDG user folders
before Pearl starts. The live desktop includes an **Install Devario** shortcut
that opens Calamares through the existing Wayland-aware installer launcher.
Live-session setup seeds Pearl's approval for that shortcut's exact location and
contents once; later edits require approval again. The shortcut and its approval
stay in the live user's home, which Calamares removes during installation along
with the setup helper. Existing users keep their preferences. Rebuild the ISO
with a Pearl package supporting `desktop_icons` to deliver these defaults.

Vimix is the default cursor for the live session, login screen, and new
installations. Build and publish `devario-core/vimix-cursors` before rebuilding
the ISO. UWSM, GTK, and GSettings defaults select the `Vimix` theme at size 24;
new users also receive editable Aqueous cursor settings. Personal cursor
choices take precedence over the session and toolkit defaults.

The live ISO and fresh installations use `adw-gtk3` as the GTK 3/4 base theme.
Build and publish `devario-core/adw-gtk3` 6.5-1 from
`devario-custom-packagbuilds` before rebuilding the ISO. GTK and GSettings
defaults select the theme; Pearl's first-session GTK Material profile layers
generated colors over it using the included Matugen. Existing user preferences
take precedence.

Papirus is the default icon theme. Publish `papirus-icon-theme` 20260801-2 from
`devario-custom-packagbuilds` before rebuilding the ISO. Papirus supplies the
GSettings default, compiled by the existing GLib transaction hook. This package
update delivers the default to existing installations. The ISO overlays select
the same theme for fresh installations. Explicit user theme choices take
precedence; log out and back
in after upgrading to refresh running applications.

Fastfetch uses a persistent system default at `/etc/xdg/fastfetch/config.jsonc`,
linked to the shared Devario configuration and fish logo under
`/usr/share/devario/fastfetch/`. Both plain `fastfetch` and the Bash/Fish welcome
display use it. The welcome display tracks the terminal rather than a global
"already shown" flag, so new terminals display it while nested shells remain
quiet. These files survive Calamares installation. Rebuild the ISO to deliver
the defaults to new installations; existing home directories keep their shell
startup files. A personal `~/.config/fastfetch/config.jsonc` takes precedence.

The package count uses Fastfetch's Devario `{shelly}` detector, which queries
`shelly list standard --show-hidden --json`. Publish the patched
`devario-core/fastfetch` 2.69.0-4 package before rebuilding the ISO; an
unpatched upstream Fastfetch does not support this format field.

The default is the seafoam-and-blue fish PNG with the DEVARIO wordmark, above
the system, hardware, and session information. The logo is 24 columns wide;
the information uses the full terminal width without a fixed-width frame or
an indented color strip. This keeps reflowed text out of the image when a
Ghostty window is narrowed after the welcome display has finished. Long values
can still wrap normally, and the logo can be clipped in windows narrower than
24 columns. Fastfetch automatically
uses the terminal's image support (including Ghostty), or Chafa text rendering
when available. ImageMagick and Chafa are explicitly included in the ISO and
required by the Fastfetch package; its build checks enforce both image backends.
Colors follow the terminal palette, with seafoam labels.
Run `python3 scripts/preview-fastfetch.py --sample` for an illustrative Devario
preview, or omit `--sample` to detect this machine's real information.
See the [rendered example](docs/assets/fastfetch-preview.png). Recreate it with
`python3 scripts/preview-fastfetch.py --sample --render docs/assets/fastfetch-preview.png`
(requires Pillow and Noto Sans Mono).
The rendered example is an illustration assembled with Pillow; image-protocol
and resize behavior must be checked in a real terminal. To check a change, run
the preview in a wide Ghostty window, shrink the window to 40 columns, and widen
it again without rerunning Fastfetch. The image should remain above the text,
and there should be no box borders to wrap into the information.

The striped, compact, and bold text fish designs remain available; preview them
with `python3 scripts/preview-fastfetch.py all --sample`.
After installation, try one with
`fastfetch --logo-type file --logo /usr/share/devario/fastfetch/fish-compact.txt`.
To keep an alternate design, copy `/etc/xdg/fastfetch/config.jsonc` to
`~/.config/fastfetch/config.jsonc` and set `logo.source` to that logo's full path.

The first-boot Shelly keyring service explicitly runs as `User=root` so systemd
supplies the home directory required by Shelly's XDG configuration lookup.
Initialization and import of the Devario signing keys finish before the service
writes its completion marker. Rebuild the ISO to include service changes.

UPower supplies battery status, and `power-profiles-daemon` supplies Pearl's
power profiles. Both services start in the live session and are enabled by
Calamares for installed systems; Pearl does not auto-start them. Build and
publish `devario-core/power-profiles-daemon` 0.30-1 from the custom PKGBUILDs
repository before rebuilding the ISO with these power defaults.

Calamares does not invoke a package manager during installation. Its `unpackfs` module copies the prepared live root
filesystem, and the remaining modules configure that copy for the target machine.

The ISO build stages `/etc/localtime` as a link to the packaged UTC timezone,
preventing systemd's initial setup service from prompting for a timezone at boot.
Calamares applies the user's selected timezone to the installed system.

ISO construction verifies that every Devario-owned package is present exactly
once in the local repository before installing the live root. In particular,
`linux-devario`, `linux-devario-headers`, and `devario-dracut` must be supplied
as signed packages from the external package build. Their recipes are maintained
outside this OS repository. The Devario builder transaction also compares its requested package
list with Shelly's installed inventory and refuses a partial root filesystem.

UFW is included and enabled on both the live ISO and installed system. The
late image overlay sets `ENABLED=yes`, enables IPv6 filtering, denies incoming
and forwarded connections by default, and allows outgoing connections, using
UFW's packaged baseline rules. Calamares preserves these settings and enables
`ufw.service` for installed boot. This follows
[CachyOS's firewall defaults](https://github.com/CachyOS/cachyos-calamares/blob/cachyos/src/scripts/enable-ufw).
No incoming service ports are opened automatically. Use `sudo ufw allow ssh`
to permit SSH when needed, and `sudo ufw status verbose` to inspect the policy.
Configuration is staged as files; building or installing the image does not
run UFW against the build host or live session's firewall.

The live filesystem includes `nvidia-open-dkms`, `nvidia-utils`, and the Devario
kernel headers. ISO staging generates the open-driver PCI support table,
including subsystem IDs, from the exact signed DKMS package selected in the
repository snapshot and requires matching driver/library versions. The
checked-in table is a reference snapshot; staging replaces it on every build.
Before partitioning, Calamares detects NVIDIA display controllers and verifies
the selected payload and headers in the pristine installation image. Hardware
outside the open driver's support table uses the cached proprietary 580 driver
when it supports all detected controllers; otherwise installation stops with
a diagnostic. See [NVIDIA install policy](docs/nvidia-install-policy.md).

After copying the offline image, Calamares verifies or builds the modules for
the target kernel and enables `NVIDIA_EARLY_KMS="true"` in the target's
`/etc/devario-dracut.conf`. The active Devario boot builder includes and requests
early loading of all four NVIDIA modules in both normal and fallback images,
with firmware and modesetting configuration checked before publication.
Installations without a connected NVIDIA GPU skip NVIDIA preflight, remove
the copied NVIDIA driver packages from the target, and disable early KMS.
After the installation upgrade, Calamares verifies the resulting
driver version against the compatible-GPU table in the signed DKMS package's
`/usr/src/nvidia-<version>/README.md`, checks the matching utilities, headers,
sources and firmware, and verifies or rebuilds the target modules again.
The initial payload checks use the support table generated during ISO staging.

A boot service also detects NVIDIA PCI display
controllers through sysfs, loads `nvidia_drm` with modesetting before greetd,
and records `nvidia`, `partial`, `unavailable`, or `none` in
`/run/devario/gpu-driver`. The `nvidia-utils` Nouveau blacklist is intentionally
left intact, so this image supports Turing-and-newer NVIDIA hardware through
the open kernel module and does not fall back to Nouveau on older GPUs.

The live and installed desktop include `bolt` and `boltctl`, built as two
packages from the Bolt source release. Upstream udev rules and D-Bus activation
start `bolt.service` when needed; it is a static service and does not need
`systemctl enable`. Use `boltctl list` to inspect an enclosure, then
`boltctl authorize UUID` for a connection or `boltctl enroll --policy auto UUID`
to remember a trusted enclosure. Authorization uses Bolt's upstream Polkit
policy. There is no blanket authorization rule or Pearl authorization UI.
Trust enrolled in the live system is not copied into the installed system's
pristine payload; enroll the enclosure again after installation.

`devario-gpu-hotplug.service` listens for processed PCI events and refreshes
`/run/devario/gpu-driver`, including after enclosure authorization, removal, and
reconnection. It loads NVIDIA DRM with modesetting when needed without
restarting the desktop or unloading drivers. A packaged modprobe setting also
enables modesetting when udev loads NVIDIA first.

GPU detection no longer disables NVIDIA in UWSM's shared application
environment. `graphics-session` applies the no-NVIDIA startup workaround only
to the greeter and the Aqueous compositor process tree. Applications started
directly by that process tree can inherit its startup restrictions; use the
included launcher to select from current hardware and override inherited GPU
filters:

```sh
devario-gpu-run --list
devario-gpu-run nvidia -- application arguments
devario-gpu-run 0000:05:00.0 -- application arguments
devario-gpu-run auto -- application arguments
```

Use a PCI address from `--list` for an AMD/Intel Mesa GPU. `nvidia` requests
NVIDIA render offload; `auto` clears GPU selection while preserving inherited
driver preferences. Explicit Mesa selection filters Vulkan drivers and uses
the Mesa device-select layer when installed. Selection
applies to the newly launched process, not an already-running application or
compositor. Physical hot-plug, external-monitor, suspend/resume, and removal
acceptance testing is still required before claiming seamless eGPU support.
Build and publish `bolt`, `boltctl`, and `python-pyudev` before rebuilding the ISO.

The live ISO and installed system use Plymouth with the Devario theme. The
late image overlay selects `Theme=devario` in `/etc/plymouth/plymouthd.conf`,
which Calamares carries into the installed filesystem. Both dracut profiles
include Plymouth, live and installed boot entries use `quiet splash`, and
Pearl waits for Plymouth to release the display. Plymouth and theme package
updates regenerate installed initramfs images through the Devario boot hook.
Publish `devario-boot` 1-10 or newer along with `plymouth` and
`devario-plymouth-theme` before rebuilding the ISO. Visual splash, greeter
handoff, and encrypted-root unlock still need BIOS/UEFI and installed boot
acceptance testing.

`devario-boot` 1-11 installs a post-transaction kernel upgrade hook that asks
logged-in local Wayland and X11 desktop users to reboot. It sends one
notification per user per transaction and prints the reminder in the package
manager output. Live-image and chroot transactions are skipped; a missing
desktop notification service does not fail the update. Publish the updated
package to deliver the hook to existing installations and future ISOs.

The live account declarations are added only after ISO package hooks finish.
They remain available for systemd to create `liveuser` in the writable live
session at boot, but the account is not materialized in the SquashFS copied by
Calamares. Target preparation also removes any legacy `liveuser` account as a
defense against images built before this separation was introduced.

Calamares creates installed users with `/usr/bin/fish`, and Devario's Shadow
package supplies the same default for `useradd`. `devario-base` 3-12 requires
Fish and `shadow>=4.20.0.arch1-3`; publish those packages before rebuilding the
base package and ISO. The Fish skeleton configuration shows the existing
Fastfetch welcome once per interactive terminal. Existing accounts retain
their selected login shell, and root and system scripts continue to use Bash
or their declared interpreter.

Installations require 64-bit UEFI. Automatic partitioning creates a GPT disk
with a 4096 MiB FAT EFI System Partition mounted at `/boot`; manual layouts
must provide the same mount and EFI partition type. Calamares checks UEFI
before partitioning. The live USB can still boot through legacy BIOS for live
use, but must be rebooted in UEFI mode before installing.

The native ISO build prerequisites and pending full-image verification are
documented in [ISO construction](docs/ISO-BUILDER.md). Snapshot and bootstrap
URLs in release examples must be provisioned before use.

## Package-management boundary

Shelly handles package transactions and signing-key management during package
builds, ISO construction, live use, installation, and installed-system operation:

| Environment | Package-management components |
| --- | --- |
| Live and installed system | `shelly`, `devario-base`, and `devario-keyring` |
| Package build host | Shelly synchronizes repositories and installs declared build dependencies. The default ISO workflow uses `shelly build` for native package builds in an isolated root. |
| ISO build host | Pinned `devario-iso-builder` with a declarative manifest; synchronization, installation, and inventory run through Shelly. |

Use `shelly build` to create packages, `shelly install standard` to install
repository packages or local archives, and `shelly keyring` to manage signing
keys. The ISO workflow calls `scripts/build-packages-core.py`, which invokes
Shelly's native builder as an unprivileged user inside the prepared build root.

Shelly's native RLPM backend uses `/etc/shelly.conf`, `/etc/shelly.d/gnupg`,
`/etc/shelly.d/hooks`, `/var/lib/shelly`, and `/var/cache/shelly/pkg` directly.
Live and installed systems enable `devario-core` first, followed by
`devario-browser`, `devario-development`, `devario-entertainment`, `devario-gaming`,
`devario-utilities`, `devario-productivity`, and `devario-libs`.
Each repository requires package and database signatures
verified through the existing Devario keyring. Calamares copies this configuration
into the installed system. Network access is optional for installation; unavailable
updates produce a visible completion warning.

After user, network, NVIDIA, bootloader and service configuration, the last
installation phase initializes the target keyring, runs
`shelly sync standard --no-confirm`, then
`shelly upgrade standard --no-confirm`. These commands run inside the installed
target with the native RLPM backend; the live session's package state is not
updated. Before partitioning, the installer checks access to every configured
repository, including any edition repositories, and treats connectivity failures
as advisory. It checks connectivity again inside the target before synchronization,
so a connection restored during installation can still be used. Package and database
signature verification remains governed by the signed runtime repository configuration.

The update wrapper temporarily supplies the live system's resolved DNS
configuration and restores the target's original file or symlink afterward,
including on failure. A missing or empty live resolver is allowed for offline
installation. Connectivity probes have a 30-second budget and synchronization
gets up to three attempts of 60 seconds each. If connectivity or synchronization
fails before the upgrade starts, the installer records `updates-pending`, completes
cleanup and shows “Installation complete — updates pending” with instructions to
update using Shelly after restarting. Failed synchronization never starts an upgrade
using stale or partially refreshed databases. Every failure once the upgrade starts
is fatal, including download, signature, transaction, driver and boot-file failures;
package upgrades are never automatically retried. Invalid repository configuration,
local keyring initialization failures and cleanup failures also stop installation.
An interrupted resolver backup is retained for recovery rather than overwritten
by a later attempt.

After the upgrade, Calamares verifies NVIDIA modules against the installed
driver and kernel and regenerates the boot images and systemd-boot entries.
When updates are skipped, the earlier NVIDIA and bootloader installation remains
in place. Both successful update paths and pending-update paths proceed through
final keyboard configuration and unmounting before reporting installation success.
The warning result is copied into the live session before unmounting and cleared
at the next preflight. Update diagnostics, before/after package inventories,
and `result.json` with completion status and
repository database hashes are stored in `/var/log/devario-installer-update/`.
Pending updates record the phase and reason; after-update inventories and database
hashes are only recorded when those steps complete.
The image's original package inventory remains the record of the ISO contents;
the installed system may contain newer packages.

`devario-base` supplies this configuration and storage layout. New images do
not enable the old storage-relocation service. The historical migration utility
is retained in source for previous installations, but is not installed by the
current base recipe.

Rebuild `devario-base` 3-15 and the ISO to include all eight repository defaults.

The desktop comes from `devario-core/devario-desktop`, with stable Aqueous and
`pearl-greeter`. Starting with 1.0.5-2, `devario-desktop` requires
`devario-system-integration`, which owns GPU services, helpers and OS desktop
configuration. The ISO obtains those files from the package. Existing ISO
installations need the [one-time file ownership migration](packages/devario-system-integration/README.md#existing-installations-one-time-adoption)
before their first upgrade. Publish integration 1-1 before Aqueous 1.0.5-2,
then rebuild the ISO. Future integration changes update through Shelly.

### Intel onboard audio firmware

The ISO and `devario-base` 3-18 require `sof-firmware` and `alsa-ucm-conf`.
These supply the DSP firmware, topology files, and ALSA use-case configuration
needed by supported Intel onboard audio devices. Missing SOF files prevented
the ASUS V16 V3607VH's onboard audio from initializing; installing these packages
and rebooting resolved the reported issue.

Build and publish `devario-base` 3-18 with both dependencies available in the
repository, then rebuild the ISO. Existing users receive the dependencies with
`sudo shelly upgrade standard` and should reboot afterward. For an immediate
repair, run `sudo shelly install standard sof-firmware alsa-ucm-conf` and reboot.
Verify that `aplay -l` lists onboard audio and `wpctl status` shows its devices.

### Realtime audio and existing installations

The default desktop and ISO require `rtkit` so PipeWire can request realtime
scheduling through D-Bus. RTKit activates on demand; no manual service enablement,
realtime group membership, or custom priority limits are needed.

For an installed system reporting `Unit rtkit-daemon.service could not be found`,
install the package and reboot:

```sh
sudo shelly install standard rtkit
systemctl reboot
```

After logging back in, play audio and check the service, current-boot user
journals, and processing threads:

```sh
systemctl status rtkit-daemon.service --no-pager
journalctl --user -b -u pipewire.service -u pipewire-pulse.service -u wireplumber.service --no-pager
ps -eLo pid,tid,cls,rtprio,ni,comm | rg 'pipewire|wireplumber|data-loop'
```

RTKit should activate successfully, and active audio processing threads should
show realtime scheduling (`FF` or `RR`) with positive `RTPRIO`. Other threads may
still use `TS`. Confirm that the RTKit `ServiceUnknown` errors no longer appear
in the new boot. A zero process realtime-priority limit alone is not a failure:
RTKit grants thread priorities through D-Bus.

For automatic delivery to existing installations, rebuild and publish the six
`aqueous-desktop` outputs at `1.0.5-2` from
[Aqueous's active recipe](https://github.com/Seafoam-Labs/Aqueous/tree/main/packaging/devario/aqueous-desktop).
Its `devario-desktop` output requires `rtkit` and `devario-system-integration`.
Ensure `rtkit` and its dependencies are available in the signed repository;
its recipe is `devario-custom-packagbuilds/devario-core/rtkit/PKGBUILD`.
Complete the [one-time integration migration](packages/devario-system-integration/README.md#existing-installations-one-time-adoption)
before the first upgrade to this desktop release. After adoption,
`sudo shelly upgrade standard` delivers later package updates. Reboot and repeat the checks above. Rebuild the ISO
with the updated repository for live sessions and fresh installations.

Release verification must cover both an upgrade of an affected installation
without reinstalling and a fresh installation from the rebuilt ISO. Source
validation alone does not establish successful runtime scheduling.

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
shelly keyring populate devario-core
```

Build a reviewed PKGBUILD with Shelly's native builder:

```sh
shelly build --review-only --json /path/to/PKGBUILD
shelly build --isolated --check /path/to/PKGBUILD
```

The first command reviews the recipe without building; the second builds in an
isolated environment and runs the recipe's checks.

Shelly requests elevation for privileged transaction steps. Run it as the invoking desktop user rather than wrapping the
whole command in `sudo`. Use full upgrades rather than synchronizing repositories and installing individual packages
into an otherwise stale system.

## Build prerequisites

Devario can build itself. Use an up-to-date Devario x86-64 system with Shelly
configured, and install the required ISO assembly and packaging tools through
Shelly:

Python validation dependencies are prepared automatically in an isolated virtual
environment from hash-pinned wheels. Python must provide `venv` and `ensurepip`;
no `python-jsonschema` repository package is required. See
[Python validation preparation](docs/ISO-BUILDER.md#python-validation-preparation)
for offline caches and standalone validator commands.
Source validation also requires Node.js to execute the live installer's Polkit
rule against allowed and denied authorization requests.

```sh
shelly install standard --upgrade python nodejs libisoburn dosfstools mtools squashfs-tools openssl util-linux base-devel git
```

For virtual-machine testing, the QEMU helper installs `qemu-desktop` and
`edk2-ovmf` through Shelly and prepares host KVM access when available:

```sh
./scripts/setup-qemu.sh --install-only
```

Devario includes Shelly as its system package manager. The build uses the host's
configured Shelly installation to prepare its tools and dependencies.

Use a systemd host with systemd-nspawn available. The ISO workflow prepares an
isolated build root from verified Devario packages, including the compiler and
recipe dependencies, and runs `shelly build` as an unprivileged user inside it.
This keeps host toolchain settings out of the package build.

Run `./build-iso.sh` as your normal user. It requests elevation for provisioning
and ISO assembly, where image construction mounts target API filesystems while
Shelly processes package hooks and scriptlets.

## Build

To create a local Community ISO from start to finish, run
[`build-iso.sh`](build-iso.sh) from this checkout as your normal user:

```sh
./build-iso.sh
```

The script installs/upgrades host tools through Shelly, prepares the pinned
Python validation environment, validates the OS sources, downloads and verifies
the signed metadata from every repository in `repositories/defaults.json`, resolves
ISO and installer build dependencies in repository order, and downloads the
required signed packages. It builds the seven local installer packages in an isolated
root populated from that verified snapshot, audits the
resulting package set, assembles the ISO with sudo, and verifies its SHA-256
checksum. A configured Shelly installation, sudo access, and the build host
described above are prerequisites. It uses its own checkout regardless of the
current working directory; `--os-dir` or `DEVARIO_OS_DIR` selects another checkout.

The wrapper requests sudo authentication once before host setup and refreshes
the cached credentials every 30 seconds during the build. The refresh process
stops on success, failure, or interruption. Subsequent privileged steps run
noninteractively; if credentials cannot be refreshed, the build stops instead
of requesting another password. Run from an interactive terminal with sudo
credential caching enabled; no password is stored by the script.

The wrapper explicitly selects Shelly's **RLPM** backend in a private copy of
the caller's settings at `work/iso-runs/<run>/shelly-config/`. That selection
also reaches elevated dependency transactions and ISO assembly. Your normal
Shelly settings are preserved. A Shelly version that cannot select RLPM stops
the build before any package transactions.

GCC, glibc (including `crt1.o`), binutils, and all recipe build dependencies come
from that verified snapshot. The root is provisioned through the snapshot's
RLPM-only Shelly CLI, and native package builds run as an unprivileged user in
systemd-nspawn. Host compiler flags, startup objects, and CachyOS repositories
do not enter the package build. Calamares's x86-64-v3 ISA check remains enabled.
The builder records planned and installed package versions under
`work/iso-runs/<run>/packages/` and retains its root and logs there. This path
constructs the root directly from package archives; no separate bootstrap image
is required.

The local snapshot retains the `devario-core` name for compatibility with the
assembler, with core packages taking precedence over duplicate names in other
repositories. It contains the full core snapshot plus runtime and build dependencies
selected from the other repositories. Original signed metadata and package origins
are retained in `core-sources/`; package signatures remain mandatory. The combined
local database is regenerated, just as when adding the seven local installer packages.
Controlled release tooling continues to use its explicitly locked inputs.

Missing runtime or build dependencies stop the run before compilation and are listed
with their requiring packages in `core-preflight.json`. Publish missing packages
to a configured repository, then rerun with a fresh snapshot. To check metadata
without downloading packages, run `python3 scripts/stage-iso-repositories.py --check
--output /tmp/devario-repository-check` with a fresh output path.

Completed installer packages from a failed run can be reused with
`./build-iso.sh --installer-dir work/iso-runs/<previous-run>/packages/artifacts`.
This still fetches current repository metadata and verifies the resulting package set.

Each run retains its ISO, checksum, and assembler reports under
`work/iso-runs/<run>/out/`, with `build.log` beside that directory. Package and
image work is retained there too, including on failure. Downloads reuse
`work/repository-downloads`; reserve space for the full binary repository,
package builds, and unpacked live filesystem. Retries use a fresh run directory,
preserving previous snapshots and ISOs. An existing `--run-dir` is rejected.

To reuse a staged core snapshot and seven prebuilt installer packages:

```sh
./build-iso.sh --repo-dir /path/to/repo/core --installer-dir /path/to/artifacts
```

The snapshot is copied into the run before modification. `--repo-url` selects
both the download URL and the installed system's runtime repository URL.
`--skip-deps` checks installed tools without upgrading them, and `--dry-run`
prints the workflow without changing anything. See `--help` for other options.
Runtime packages such as the kernel and desktop must already be published as
signed artifacts; the script builds the seven OS-owned packages from `packages/`.
Controlled release signing/publication and VM boot acceptance remain separate
workflows. The root `build-iso.sh` orchestrates the entire local build;
`scripts/build-iso.sh` is the assembly step used by it.

For individual build steps, stage the signed repository snapshot and build the
local ISO inputs with the same native Shelly helper used by `./build-iso.sh`.
Use a fresh work directory for each build:

```sh
python3 scripts/stage-iso-repositories.py --output repo/core
python3 scripts/build-packages-core.py --repo repo/core --work work/local-packages
./scripts/stage-installer-packages.sh work/local-packages/artifacts
```

This builds Calamares, `ckbcomp`, `devario-filesystem`, `devario-base`,
`devario-boot`, `devario-keyring`, and `devario-system-integration`. These seven local ISO inputs and the regenerated build
database do not require signing. Downloaded packages retain their signature
checks. The kernel, headers, dracut, Shelly, Aqueous, `devario-desktop`, Pearl,
and `pearl-greeter` come from `devario-core`:

If those seven archives have already been built, merge their directory with
`./scripts/stage-installer-packages.sh /path/to/artifacts` instead. No local
signing key is needed for this workflow. Controlled release builds retain the
separate signing requirements described below.

Core artifacts are written only to `repo/core/`; that directory is never
shared with managed-edition artifacts.

Kernel and dracut updates belong in the external package repository.
Build them in its controlled baseline
environment and supply signed artifacts to the staged `devario-core` repository
before constructing the ISO. To check the pinned 7.2.7-1 kernel recipe in that
source checkout:

```sh
./scripts/validate-kernel-package.sh /path/to/linux-devario
```

The kernel recipe pins Seafoam Labs' signed `devario-7.2.7-1` release archive
and configuration with SHA-256 checksums. The kernel targets x86-64-v3 while
host build tools target baseline x86-64. Updating it is a maintainer operation
documented in [Kernel packaging](docs/KERNEL-PACKAGING.md); installed systems receive
the resulting binary exclusively from the signed Devario repository.

Validate package, profile, Calamares, service, and Shelly package-management invariants:

```sh
./scripts/validate.sh
```

Community is the default edition. The build first copies the canonical
`iso/` profile into a temporary directory, then applies the data-only
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

Build the ISO using the pinned Devario builder. The wrapper verifies the local
`devario-core` repository with the seven-package installer exception, extracts the Devario
Shelly binary, and initializes a temporary verification keyring outside the live
root. The declarative profile lives in `iso/profile.json`. Supply the complete
repository through `DEVARIO_CORE_REPO_DIR`.
See [ISO builder prerequisites and verification](docs/ISO-BUILDER.md).

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

The resulting image is written to `out/`, and intermediate image state is stored in `work/`. Override either location
when needed:

```sh
sudo DEVARIO_OUTPUT_DIR=/path/to/out \
  DEVARIO_WORK_DIR=/path/to/work \
  ./scripts/build-iso.sh
```

To reuse the baseline nspawn environment for ISO construction, use the nspawn
wrapper. It prepares the container when necessary, installs the ISO assembly
toolchain through Shelly, grants the container only the additional mount and
device-node capabilities needed by the image assembler, and calls the same ISO builder.
Its mutable image work tree is created inside the container rather than on
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
  DEVARIO_CORE_REPO_URL=https://mirrors.seafoam-labs.org/devario-core/x86_64 \
  ./scripts/build-iso-nspawn.sh
```

## Repository signing and publication

With no `DEVARIO_REPO_URL`, the ISO builder embeds the development repository at `/opt/devario/repo` and configures the
installed system to use it with `Optional TrustAll`. That mode works offline but is not suitable for publication. The
temporary repository used only while constructing the image has `SigLevel = Never`, because the build host does not own
Devario's trust root; this does not become the installed configuration.

The local Community workflow builds the seven installer packages with Shelly's
native builder. Publication additionally requires signed packages and repository
metadata, the production public keyring, and HTTPS repository endpoints. The
local build's unsigned installer-package exception is limited to ISO construction.

Before publishing a release:

1. Create a dedicated offline-controlled Devario package-signing key. Never commit its private material.
2. Sign every published package archive and the repository database. Shelly supports
   package signing with `shelly build --sign --key <fingerprint> /path/to/PKGBUILD`;
   repository metadata must also be signed before publication.
3. Distribute the exported public key through `devario-keyring`. The Shelly keyring service runs
   `shelly keyring populate devario-core` and remains enabled so a freshly installed target initializes its own keyring.
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

UEFI and BIOS use separate persistent disks below `out/qemu/`. The graphical
helper enables Venus with `virtio-vga-gl,hostmem=4G,blob=true,venus=true` and
shared memfd guest RAM. Aqueous requires Vulkan; ordinary VirGL OpenGL
acceleration and the guest's CPU Vulkan driver do not provide the required
Vulkan device for the virtio DRM display. The ISO therefore requires
`vulkan-virtio`, including `libvulkan_virtio.so` and its ICD manifest.
On guests whose DRM devices are all virtio GPUs, Devario also selects Zink for
GBM allocation in greetd, UWSM, and the elevated installer. This keeps display
and client buffers on Venus: importing ordinary VirGL GBM buffers into Venus
failed with the tested QEMU external EGL context. Native and mixed GPU systems
keep their existing allocator selection.

The host needs a working Vulkan driver, `vulkan-tools`, and QEMU and
virglrenderer builds with Venus support. The helper checks QEMU device options
and host Vulkan enumeration before preparing a desktop VM. The backend must
also initialize successfully at VM startup. See
[Mesa's Venus requirements and QEMU configuration](https://docs.mesa3d.org/drivers/venus.html).
`DEVARIO_QEMU_HOSTMEM` changes the GPU memory aperture; it defaults to `4G`.
`--no-gl` supports console boot testing only and cannot start Aqueous or
Pearl Greeter. `--software` changes CPU acceleration and still requests Venus
unless combined with `--no-gl`.
Intel KVM hosts additionally need QEMU 11+ and a host kernel meeting Mesa's
Venus mapping requirements; the helper enables `honor-guest-pat=on` there.

For virt-manager, select a virtio video device and enable 3D acceleration and
OpenGL display support. Check the generated QEMU command for `venus=true`,
`blob=true`, and a nonzero `hostmem`; the 3D checkbox alone does not establish
Vulkan support. Configure those properties using the installed libvirt
version's supported device overrides, and use shared memfd guest memory.
Confirm `vulkaninfo --summary` in the guest reports `DRIVER_ID_MESA_VENUS`.

For libvirt 8.2+ test domains, add
`xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0"` to the existing
`<domain>` element. Set shared memory backing as follows:

```xml
<memoryBacking>
  <source type="memfd"/>
  <access mode="shared"/>
</memoryBacking>
```

Give the existing virtio `<video>` device an alias
`<alias name="ua-venus-video"/>`, alongside its model with
`<acceleration accel3d="yes"/>`. Add this override directly under `<domain>`:

```xml
<qemu:override>
  <qemu:device alias="ua-venus-video">
    <qemu:frontend>
      <qemu:property name="venus" type="bool" value="true"/>
      <qemu:property name="blob" type="bool" value="true"/>
      <qemu:property name="hostmem" type="unsigned" value="4294967296"/>
    </qemu:frontend>
  </qemu:device>
</qemu:override>
```

Keep the display's OpenGL support enabled. These are QEMU-specific test-domain
overrides; check them against the installed hypervisor versions. See
[libvirt's device override documentation](https://libvirt.org/drvqemu.html#overriding-properties-of-qemu-devices).

Run the full live desktop probes on a host with KVM and Venus support:

```sh
python3 scripts/test-live-desktop.py --iso /path/to/devario.iso --output out/desktop-live --phase live
python3 scripts/test-live-desktop.py --iso /path/to/devario.iso --output out/desktop-greeter --phase greeter
```

Use a fresh output directory for each run. `--render-node /dev/dri/renderD129`
selects a particular host GPU on a hybrid system; use the appropriate node for
your hardware. The probes boot the candidate's exact kernel and initramfs
against its full live filesystem, verify Venus, a responsive Aqueous Wayland
display, Pearl, and a mapped Calamares window, and retain logs, the QEMU command,
an ISO digest, and a screenshot. The greeter phase exercises the packaged
installed-login configuration in the disposable live overlay. These probes
complement the BIOS/UEFI bootloader and installed-disk acceptance tests.
The on-image probe runs only when its explicit QEMU firmware request is present.
Screenshots use a private Unix VNC socket because GL scanout can lack the
surface needed by QMP `screendump`.
`result.json` records the guest checks and QEMU exit status separately, including
failed runs. Overall acceptance requires a captured display and a clean QEMU
exit; a guest pass alone does not hide a host graphics cleanup crash.

On a hybrid host, select matching host EGL and Vulkan drivers. For example,
the AMD/Mesa backend used for these probes can be selected per process:

```sh
__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json \
__GLX_VENDOR_LIBRARY_NAME=mesa \
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.json \
python3 scripts/test-live-desktop.py --iso /path/to/devario.iso \
  --output out/desktop-live-amd --render-node /dev/dri/renderD129
```

Adjust the driver paths and render node for the host. Successful Vulkan
enumeration alone does not prove that the guest compositor can match its DRM
device to the exported Vulkan device.

Before publishing an image, verify that:

1. The ISO boots in both BIOS and UEFI modes.
2. greetd automatically starts `liveuser` through UWSM in the Aqueous session,
   with Pearl running as the shell.
3. The Pearl application launcher lists Install Devario and opens Calamares
   through Polkit.
4. Automatic and manual partitioning complete successfully.
5. The installed system boots through systemd-boot in UEFI mode without the ISO attached.
   Installation launched from BIOS mode is rejected before partitioning.
6. NetworkManager and `pearl-greeter.service` are enabled on the installed system.
7. Pearl Greeter lists `Aqueous`, authenticates a user, and starts the
   packaged UWSM session.
8. `command -v shelly` succeeds, and `shelly keyring list` shows the initialized package-signing keys.
9. Shelly comes from `devario-core`, uses its native RLPM backend, and runs without `devario-alpm-runtime`.
10. With working repositories, the installer completes final Shelly synchronization
    and full upgrade; `/var/log/devario-installer-update/result.json` records `complete`.
    Exercise both an image with available updates and one already current.
    Also exercise an installation offline throughout, a connection lost before
    synchronization and a connection restored during installation. Unavailable
    connectivity or exhausted synchronization retries must finish with a visible
    updates-pending warning, usable restart option and bootable installed system.
    Confirm `result.json` records `updates-pending` and the logs retain the reason.
    Any failure after the package upgrade starts, including a download, signature,
    disk-space, driver verification or boot-hook failure, must prevent success.
11. Package install, local-package install, removal, provider resolution, and ALPM hooks work.
12. A kernel, dracut, DKMS, microcode, or systemd upgrade runs Devario's ordered
    dracut generation and boot update, refreshes
    `/boot/loader/entries/devario*.conf` and the deployed systemd-boot binaries, and leaves the system bootable.
    Verify that the active release contains `devario` in `uname -r` and that
    both normal and fallback systemd-boot entries use the matching artifact names.
    See [the boot contract and recovery instructions](docs/DRACUT-BOOT.md).
13. On Turing-or-newer NVIDIA hardware, `/run/devario/gpu-driver` contains
    `nvidia`, `nvidia-smi` succeeds, and
    `/sys/module/nvidia_drm/parameters/modeset` contains `Y`. Also verify that a
    non-NVIDIA machine records `none` and still reaches Aqueous.
14. An `execve` trace confirms that package transactions during package and ISO
    construction run through Shelly, and the default ISO workflow uses `shelly build`.

## Locale generation and recovery

The ISO retains glibc's full `/etc/locale.gen` catalog. The image builder enables
and generates `en_US.UTF-8` for the live session; Calamares enables the selected
language and regional locales during installation. Both paths verify that glibc
can load the configured locales, since `locale-gen` can return success despite
an individual generation failure.

For installations affected by [issue #12](https://github.com/Seafoam-Labs/devario-os/issues/12),
inspect `/etc/locale.conf` and `/usr/share/i18n/SUPPORTED`. Back up
`/etc/locale.gen`, then add each missing selected locale using its exact entry
from `SUPPORTED`. For German, the entry is `de_DE.UTF-8 UTF-8`. Keep existing
enabled locales, including English. Run `sudo locale-gen`, then verify German
with `LC_ALL=de_DE.UTF-8 locale charmap` (it must print `UTF-8` without warnings).
Log out and back in to refresh the graphical session's environment. Do not set
a permanent `LC_ALL` override: it would override the chosen regional formats.

Before releasing an ISO, perform a German Calamares installation and reboot.
Verify `locale`, `locale -a`, and `locale charmap` in both Aqueous and a TTY, then
confirm cava renders without an `LC_ALL` override. Also check English and mixed
language/regional settings, and confirm that the German keyboard still works
at the LUKS prompt, login screen, desktop, and TTY.

## Development limitations

- Development images deliberately trust their embedded repository. Public images must use release mode with a signed
  HTTPS repository.
- The October 6 live-boot recording also shows a failed optical-device loopback
  unit and a delay rebuilding the dynamic linker cache. Boot proceeds beyond
  both; investigate them separately from Vulkan desktop startup.
- Devario maintainers must track Seafoam Labs kernel security releases, rebuild and
  sign the pinned kernel promptly, and publish corresponding source materials.
- Calamares targets x86-64-v3 and must be built with compatible startup objects
  and dependencies. Its recipe rejects v4 startup objects, and ISO preflight
  rejects Calamares archives declaring v4 ISA requirements. Host-native builds
  on a CachyOS v4 toolchain are not compatible with the image's v3 target.
- Shelly's optional AUR workflow uses the native `shelly build` command and
  requires the recipe's build tools and dependencies. The supported default
  runtime covers signed binary repositories and local package archives.
- The inspected `aqueous-core 0.9.1-1` repository artifact retains a build-machine
  directory after `$ORIGIN/../lib/aqueous` in its ELF RUNPATH. It fails the strict
  artifact check until that package is rebuilt with only its private library path.
- The live image leaves Calamares installed on the target until removal is covered by automated installation tests.
- Secure Boot is not configured.
- Pre-Turing NVIDIA GPUs are unsupported because the image intentionally keeps
  the `nvidia-utils` Nouveau blacklist enabled.
- Shelly updates from `devario-core` must pass the package-management and boot acceptance checks before release.

## Repository layout

```text
iso/                         Devario ISO profile and live filesystem overlay
iso/shelly.runtime.conf      Installed-system Shelly configuration template
docs/                            High-level product and architecture documentation
packages/calamares/              Upstream Calamares package
packages/ckbcomp/                Calamares keyboard-layout compiler helper
packages/shelly/                 Documentation for the repository-supplied Shelly package
packages/devario-base/           Base dependencies, Shelly configuration, and storage migration
packages/devario-keyring/        Devario public package-signing keys
docs/KERNEL-PACKAGING.md         External kernel build requirements
repo/core/                       Generated core-only local binary repository
repo/managed/                    Reserved physical boundary for managed artifacts
scripts/                         Package, validation, and ISO build entry points
tools/devario-iso-builder/       Pinned Devario builder source archive and lock
```
