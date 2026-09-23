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
modes. `devario-boot` owns dracut generation and installed Limine deployment.
The builder supports the existing BIOS Syslinux/UEFI systemd-boot media layout,
renders loopback/network templates, and produces ISO checksums and JSON reports.
Every build requires a fresh work directory.

## Repository inputs

Default runtime repository order is:

| Repository | Server | Public-key package |
| --- | --- | --- |
| `devario-core` | `https://repo.seafoam-labs.org/devario-core/$arch` | `devario-keyring` |
| `seafoam-labs` | `https://repo.seafoam-labs.org/$arch` | `seafoam-keyring` |

Both repositories currently advertise fingerprint
`BB62CD2725FD8E25558F900A84F94F672976872C`. Their downloaded database signatures
were verified against that public key during implementation. The service
provides detached signatures even when database/API records lack embedded
package signatures. Each repository remains a separately recorded build input;
Managed adds its own repository and distinct trust root.

Supply complete local repository closures using `DEVARIO_CORE_REPO_DIR`
(default `repo/core`) and `DEVARIO_SEAFOAM_REPO_DIR` (default `repo/seafoam`). The
existing closure verifier requires canonical database/files archives, relative
compatibility links, and exactly the packages described by those databases.
Production inputs require detached signatures from the declared active signer.
Do not rename or regenerate signed metadata without preserving its exact bytes
and signature. Devario-owned packages, including its patched Shelly, must be
built into the core closure; a similarly named external package is not proof of
compatibility with isolated-root operations.

Audit already downloaded, signature-verified databases before staging packages:

```sh
python3 scripts/audit-iso-repositories.py \
  --database devario-core /path/to/devario-core.db \
  --database seafoam-labs /path/to/seafoam-labs.db \
  --packages iso/packages.x86_64 --output out/repository-audit.json
```

The audit resolves names, version constraints, and virtual providers, and reports
missing transitive requirements. It does not replace package-signature,
conflict-resolution, or installation checks. The initial September 23 audit
selected 492 packages and reported 73 unresolved requirements, including native
Devario packages and essential system dependencies. The report is a snapshot of
the inspected database bytes, not a permanent statement of service contents.

## Bootstrap and release inputs

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
`devario-core/x86_64/` and `seafoam-labs/x86_64/`. Downloaded database bytes and
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

Source validation and the release-contract regression suite pass. The new
filesystem/keyring/compatibility packages and changed base/boot packages build.
The actual assembler has produced a minimal hybrid ISO that boots through BIOS
and UEFI using the host's previously generated dracut probe. That is a media
integration test, not the complete Aqueous desktop image.

Full desktop ISO generation, installation/reboot, update acceptance, and
network/loopback boot acceptance remain pending complete signed package and
bootstrap inputs and a privileged build runner. CMS artifact verification is
tested separately from network boot. No release acceptance or production
attestation has been fabricated for these pending checks.
