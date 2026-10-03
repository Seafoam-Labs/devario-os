<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Devario ISO construction

The image assembler is maintained in the private
[`Seafoam-Labs/devario-iso-builder`](https://github.com/Seafoam-Labs/devario-iso-builder)
repository. `tools/devario-iso-builder/source.lock.json` pins its commit and
archive SHA-256; the matching source archive is included for offline builds.
`scripts/run-iso-builder.py` verifies that archive before invoking it in a private
mount namespace. `release/source-manifest.json` records its source provenance.

`devario-os` owns edition composition, package selection, trust policy, and
release authorization. The builder reads JSON and does not execute profile shell
code. `iso/profile.json` selects x86_64, the kernel identifier, and target file
modes. `devario-boot` owns dracut generation and installed systemd-boot deployment.
The builder supports the existing BIOS Syslinux/UEFI systemd-boot media layout,
renders loopback/network templates, and produces ISO checksums and JSON reports.
Every build requires a fresh work directory.

## Repository inputs

Community uses only `devario-core`, served at
`https://repo.seafoam-labs.org/devario-core/$arch` and trusted through
`devario-keyring`. A Managed edition can add its explicitly supplied managed
repository. The separate `seafoam-labs` repository is no longer an ISO input.

Supply complete local repository closures using `DEVARIO_CORE_REPO_DIR`
(default `repo/core`). The
existing closure verifier requires canonical database/files archives, relative
compatibility links, and exactly the packages described by those databases.
Production inputs require detached signatures from the declared active signer.
Do not rename or regenerate signed metadata without preserving its exact bytes
and signature. Devario-owned packages, including its patched Shelly, must be
built into the core closure; a similarly named external package is not proof of
compatibility with isolated-root operations.

Stage the published repository with its complete signed package closure:

```sh
python3 scripts/stage-core-repository.py
```

This downloads into `work/repository-downloads`, verifies the active signer and
package hashes, then publishes a complete local snapshot at `repo/core`.
Metadata bytes and signatures are preserved; the local canonical archive names
remain `.tar.zst` even if the upstream metadata is gzip-compressed. Failed
transfers retain verified cache files for retry. A later refresh must use a
fresh destination, for example `--output repo/core-next`, so the existing
verified snapshot is not overwritten.

For a local ISO, the six OS-owned packages (`calamares`, `ckbcomp`,
`devario-filesystem`, `devario-keyring`, `devario-boot`, and `devario-base`) may
be built locally without signatures. Merge a directory containing their archives
into the staged snapshot with:

```sh
./scripts/stage-installer-packages.sh work/iso-preparation/artifacts
```

This regenerates the local build database without signing it, verifies every
other package against the bundled active signing key, and checks database hashes,
dependency resolution, and hook paths before replacing `repo/core`. The previous
snapshot is preserved alongside it. Any supplied package signature must still
verify, including signatures on OS-owned packages. The exception applies to
local ISO construction; controlled production release inputs retain their signing
requirements. Runtime repository configuration still requires signatures. Some
OS-owned packages remain installed after installation; this exception does not
change the policy for future repository downloads.

The temporary build configuration sets `SigLevel = Never` in both `[options]`
and the local repository section, after the wrapper's archive verification.
Shelly revision `1913c78d` treats a repository's zero-valued `Never` policy as
inheritance, so a global `Required` policy incorrectly rejects these unsigned
installer inputs. `shelly.runtime.conf` continues to require signatures.
Native assembly output is retained in `out/devario-iso-assembler.log`; its last
200 lines are also included in the failure report. Retry failed assembly with a
fresh `DEVARIO_WORK_DIR`; the assembler does not resume populated work trees.

The command emits dependency and installed-path audit reports beside the staged
repository. A nonzero result can mean the signed snapshot was staged correctly
but is not yet ISO-ready: missing OS packages need local staging, and downloaded
packages with old hook paths need rebuilt repository artifacts. The ISO build repeats these preflight checks and
requires the Shelly public-key-directory patch, preventing silent omission of
package hooks. The current source recipe folder is not evidence that the
published archive already contains its changes.

Audit already downloaded, signature-verified databases before staging packages:

Version comparisons require either `vercmp` or the ALPM shared library. Ubuntu
24.04 CI installs `libalpm13t64` and uses its `alpm_pkg_vercmp` directly when
`vercmp` is absent.

```sh
python3 scripts/audit-iso-repositories.py \
  --database devario-core /path/to/devario-core.db \
  --packages iso/packages.x86_64 --output out/repository-audit.json
```

The audit resolves names, version constraints, and virtual providers, and reports
missing transitive requirements. It does not replace package-signature,
conflict-resolution, or installation checks. The initial September 23 audit
selected 492 packages and reported 73 unresolved requirements, including native
Devario packages and essential system dependencies. The report is a snapshot of
the inspected database bytes, not a permanent statement of service contents.

## Python validation preparation

The ISO workflow prepares a dedicated virtual environment automatically. It uses
`python-jsonschema`'s upstream Python distribution and its runtime dependencies,
plus PyYAML for source checks. These tools are not installed into the live image
and do not require Remora packages or publication in `devario-core`.

To prepare ahead of time or run a standalone validator:

```sh
python3 scripts/prepare-validation-env.py
./scripts/with-validation-env.sh python3 release/validate-json.py SCHEMA DOCUMENT
./scripts/validate.sh
```

Use CPython 3.11–3.14 on Linux x86_64 or aarch64, with `venv` and `ensurepip`
available. Debian/Ubuntu hosts need `python3-venv`; Devario uses its Python
package. The lock at `scripts/validation-requirements.lock` pins versions and
wheel SHA-256 hashes. Installation requires binary wheels and cannot fall back
to source compilation, so maturin, Rust, setuptools bootstrap packages, and
system pip are not needed. Pip is bootstrapped from Python's bundled ensurepip.

User environments default to `$XDG_CACHE_HOME/devario/validation-python`
(or `~/.cache/devario/validation-python`); root uses
`/var/cache/devario/validation-python`. `DEVARIO_VALIDATION_CACHE` overrides the
host cache. Environments are keyed by the dependency lock, Python version, and ABI/platform.
Build commands activate them for child Python processes and disable user-site
imports and bytecode writes.

Preparation normally downloads wheels from PyPI over HTTPS and verifies their
locked hashes. For offline preparation, copy a previously prepared `wheels/`
directory for the target Python version and architecture, then set:

```sh
export DEVARIO_VALIDATION_OFFLINE=1
export DEVARIO_VALIDATION_WHEELHOUSE=/absolute/path/to/wheels
python3 scripts/prepare-validation-env.py
```

Supply these variables to sudo explicitly when invoking a root build; sudo may
remove the invoking user's environment. Host and container Python ABIs can
differ, so an offline cache must include compatible wheels for both.

The nspawn preparation step creates its own environment under
`/opt/devario/validation-python` using the container's interpreter. It runs
before recording the controlled builder's root-tree hash, which therefore
covers the installed Python tools and their lock identity. A controlled build
only checks and reuses that environment; it cannot download or install tools
after attestation. The host virtual environment is never bind-mounted as the
container interpreter.

## Bootstrap and release inputs

The `devario-iso-builder` checkout is the image assembler, not a bootstrap
root filesystem. A provisioned native host can run `sudo ./scripts/build-iso.sh`
with the signed core repository staged locally, without a bootstrap archive.
The host needs Python 3.11–3.14 with `venv`/`ensurepip` and the documented image
tools. The assembler uses the patched `shelly-cli` split package with explicit
`--config` and `HookDirMode = Replace`; no host configuration mount is required.

The vendored archive includes the local assembler integration changes and their
`LOCAL-CHANGES.patch`. Its lock records the upstream base revision, local patch
hash, and complete archive hash; it does not claim those changes were published
upstream. The matching changes are also in the sibling assembler checkout.

The default nspawn path requires a signed Devario bootstrap through
`DEVARIO_BOOTSTRAP_URL`; no Arch bootstrap URL is assumed. The archive has one
top-level root directory, identifies as Devario in `/etc/os-release`, and carries
its installed-package database under `/var/lib/shelly`. It must contain the
userspace and package-build tools required by the selected recipes. Its detached
signature is verified using `DEVARIO_BOOTSTRAP_KEYRING`, defaulting to the checked
in core public-key bundle. A complete bootstrap artifact has not been produced
as part of the current verification.

Controlled builds additionally require an immutable
`DEVARIO_REPOSITORY_SNAPSHOT_URL` of the form
`https://HOST/snapshots/IDENTIFIER/`, with repositories at
`devario-core/x86_64/`. Downloaded database bytes and
signatures are locked and checked against Shelly's actual synchronized databases.
Publish this snapshot layout explicitly; the live repository URLs are not an
immutable snapshot service by themselves.

Controlled-builder manifests, core input locks, image build records, and builder
attestations use schema version 2. They record the independent assembler and
named repository inputs. Version 1 schema files are retained for identifying old
evidence; current release validation does not silently reinterpret version 1.

## Identity and compatibility

`devario-filesystem` owns the base filesystem and release identity, replaces the
compatible `filesystem` provider, and supplies no Arch release marker. The
edition-specific `/etc/os-release` is a package backup file; `/usr/lib/os-release`
links to it so an upgrade preserves the selected edition. Neither edition
declares `ID_LIKE=arch`.

`shelly-arch-compat` is an optional package, excluded from the default native
package build set and ISO. Build it explicitly when needed. Run
`sudo shelly-arch-compat enable` to initialize Arch trust and append its managed
repository block. Run `sudo shelly-arch-compat disable` to remove that block.
User repository definitions are never overwritten. Disabling repositories leaves
already installed packages and verification keys intact and prints an inventory
for review; local ALPM records do not reliably retain repository provenance.

A transaction hook blocks changes to protected identity, base, package-manager,
and boot packages while compatibility is enabled. Disable compatibility before
updating those packages from Devario repositories. This makes the protection
explicit without silently selecting external replacements.

## Verification status

Source validation and the release-contract regression suite pass. The current
published RLPM CLI also passed synchronization, installation, and inventory
against a disposable repository and target, with host hooks masked and host
configuration bytes unchanged. The ISO selects the published `devario-desktop`
and stable `pearl-greeter`; OS login/GPU defaults are supplied by its profile. The new
filesystem/keyring/compatibility packages and changed base/boot packages build.
The actual assembler has produced a minimal hybrid ISO that boots through BIOS
and UEFI using the host's previously generated dracut probe. That is a media
integration test, not the complete Aqueous desktop image.

Full desktop ISO generation, installation/reboot, update acceptance, and
network/loopback boot acceptance remain pending complete signed package and
bootstrap inputs and a privileged build runner. CMS artifact verification is
tested separately from network boot. No release acceptance or production
attestation has been fabricated for these pending checks.
