# Devario kernel package

The kernel recipe is maintained outside this OS repository following the package
relocation in `dc737f4`. The instructions below preserve the build requirements
for the 7.2.7-1 recipe; apply them in the external package source checkout.
The OS builder consumes signed kernel and header packages from `devario-core`.

Run `scripts/validate-kernel-package.sh /path/to/linux-devario` from the OS
checkout to validate this version's recipe and configuration in their external
location. This preserves the source checks separately from OS validation;
source signature verification and package builds remain the package builder's
responsibility. The image build still requires both signed binary packages.

This standalone recipe builds `linux-devario` and `linux-devario-headers`
**7.2.7-1** from the signed **devario-7.2.7-1** release of
[Seafoam-Labs/linux](https://github.com/Seafoam-Labs/linux/releases/tag/devario-7.2.7-1).
The release tag resolves to commit
`00a4b3afc99f9413ff9ad168c2fdbe3f788eb9e5`. It is deliberately independent of
the moving `7.2/devario` branch.

Makepkg reads the release archive and detached signature from this directory.
The archive, signature, config, and public key all have pinned SHA-256 checksums.
Makepkg verifies the archive signature against release signer
`399521CE9D6D65B35EEF0F8C79AFA05ABDB26C5A` (Piotr Gorski). The commit above
records the release's source provenance; the archive is authenticated through
its checksum and signature rather than a Git checkout. Package signing uses
the repository owner's separate signing key.

The configuration is adapted from Devario's former
CachyOS LTS configuration, then normalized with this release's
`olddefconfig`. It retains broad hardware support, Rust, BTF, dracut live-root
support, and module signing. It uses GCC, no LTO, an x86-64-v3 CPU target,
and the `devario` hostname. The recipe checks required settings after
`olddefconfig`, so a missing Rust toolchain cannot silently disable Rust.
It also checks GCC and GNU ld selection and `CONFIG_LTO_NONE=y`; makepkg LTO
is disabled with `!lto`. Clang/LLVM remain build dependencies for Rust bindings
and tooling. The kernel explicitly depends on `dracut` for initramfs generation.

Both packages use kernel release `7.2.7-1-devario`. The kernel package contains
the image, modules, `pkgbase`, and Devario kernel metadata under
`/usr/lib/modules/7.2.7-1-devario/`. Headers depend on the exact kernel package
version. Neither package replaces or conflicts with `linux-cachyos-lts`.

## Build with Remora

Register the package as **`linux-devario`** and place these five files together
at one level in its source directory:

```text
PKGBUILD
config
release-signing-key.pub
devario-7.2.7-1.tar.gz
devario-7.2.7-1.tar.gz.asc
```

Use the supplied release asset, not a newly generated GitHub source snapshot:
its bytes must match the pinned checksum. The builder needs no GitHub access.
`.SRCINFO` and `README.md` are optional metadata/documentation; omit `.SRCINFO`
from Remora's web uploader, which rejects dotfiles.

The inspected Remora uploader limits each file to 1 MiB, while this archive is
approximately 254 MiB. If that limit remains on your server, upload the four
small input files and copy the tarball directly into the same server-side
package directory (`<PkgbuildsDir>/<repository-id>/linux-devario/`) before
queueing. Alternatively, register the complete directory as a local source.
A server with a sufficiently increased upload limit can accept all five inputs
through its uploader.

Use Remora's **Makepkg** engine (`SystemSettings.BuildEngine = Makepkg`) on
an x86-64 Arch-compatible builder with `base-devel`, dependency installation,
and package signing configured. Enable copying the uploaded package into the
build workspace. The inspected Shelly 3.1.6 engine rejects this large local
archive during review because of its 32 MiB local-file limit.

Before enqueueing, import the source signing key into Remora's configured
**build user's** GPG keyring, replacing the example account and path:

```sh
sudo -u builder gpg --import /path/to/linux-devario/release-signing-key.pub
```

Makepkg verifies sources before running `prepare()`, so the import must happen
before the job. This public key does not replace the builder's own private
package-signing key.

Remora runs `makepkg --verifysource --noconfirm`, followed by
`makepkg -sr --sign -f --noconfirm`, and collects both split packages using
`makepkg --packagelist`. The builder must support dependency installation and
signing without interactive prompts. All kernel sources are supplied locally;
no clone or authenticated source download is performed.

Rust requires matching `rust-src`, and bindgen requires libclang; these are
declared in `makedepends`. Set `MAKEFLAGS` in the builder's makepkg configuration
to choose parallelism. The recipe does not force all host CPUs into use.

The outputs to sign and upload to the binary repository are:

- `linux-devario-7.2.7-1-x86_64.pkg.tar.zst`
- `linux-devario-headers-7.2.7-1-x86_64.pkg.tar.zst`

Sign both package archives and refresh/sign `devario-core`'s database through
the repository's normal publication process. Retain the pinned source revision
alongside the build evidence. The PKGBUILD itself is a build input;
installers consume the resulting binary packages.

## Integration and release checks

`linux-devario` is the default kernel selected by the ISO profile, build
scripts, installer, boot helpers, and edition protection rules. Live, normal,
fallback, and recovery images use the `linux-devario` boot identity. NVIDIA
validation requires the matching `linux-devario-headers` package.

Before production publication, complete a full build, verify package contents,
compile NVIDIA DKMS against the headers, and test BIOS/UEFI boot, dracut
generation, and a kernel upgrade. Source verification and successful
configuration preparation alone do not establish those results.

Checked on 2026-09-27: Bash syntax, makepkg metadata, all local source checksums,
archive signature, extraction, and `prepare()` passed with GCC/BFD, LTO disabled,
x86-64-v3 selected, and Rust enabled. The kernel release is `7.2.7-1-devario`.
An earlier archive-based configuration also passed `modules_prepare`. A complete
kernel/package build, Remora job, and boot/DKMS tests have not yet been run.

For an upstream update, change `_tag`, `_commit`, `_source_epoch`, `pkgver`,
archive/signature checksums, and normalized config/checksum together; verify
the new release's signing key. For a packaging-only rebuild, increment
`pkgrel`; `_tag` remains unchanged. Regenerate `.SRCINFO` with
`makepkg --printsrcinfo > .SRCINFO`.
