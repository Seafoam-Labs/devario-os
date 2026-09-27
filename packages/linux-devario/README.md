# Devario kernel package

This standalone recipe builds `linux-devario` and `linux-devario-headers`
**7.2.7-1** from the signed **devario-7.2.7-1** release of
[Seafoam-Labs/linux](https://github.com/Seafoam-Labs/linux/releases/tag/devario-7.2.7-1).
The release tag resolves to commit
`00a4b3afc99f9413ff9ad168c2fdbe3f788eb9e5`. It is deliberately independent of
the moving `7.2/devario` branch.

Makepkg clones the private repository using its Git source handler, checks out
`devario-7.2.7-1`, and verifies the tag signature against the pinned release
signer, `399521CE9D6D65B35EEF0F8C79AFA05ABDB26C5A` (Piotr Gorski).
`prepare()` additionally rejects a checkout whose commit differs from the pin
above. The Git source uses `SKIP` for its archive checksum; the config and
included public key retain pinned SHA-256 checksums. Package signing uses the
repository owner's separate signing key.

The configuration is adapted from Devario's existing
`packages/linux-cachyos-lts/config`, then normalized with this release's
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

Register the package as **`linux-devario`** and upload these three flat files:

```text
PKGBUILD
config
release-signing-key.pub
```

No source archive or detached archive signature is needed. `.SRCINFO` and
`README.md` are optional local documentation/metadata; omit `.SRCINFO` from
Remora's web uploader, which rejects dotfiles.

Use Remora's **Makepkg** engine (`SystemSettings.BuildEngine = Makepkg`) on
an x86-64 Arch-compatible builder with `base-devel`, Git, dependency
installation, and package signing configured. Enable copying the uploaded
package to its build workspace. A complete mirror of the kernel Git repository
can require substantial disk space and download time on the first build.

Before enqueueing:

1. Configure noninteractive HTTPS Git access to `Seafoam-Labs/linux` for
   Remora's configured **build user**. The service account's GitHub access alone
   is insufficient if builds run as a different user. Keep credentials outside
   the PKGBUILD and uploaded files.
2. Ensure that authentication also works under makepkg: current makepkg ignores
   the user's global Git config and reads `/etc/makepkg.d/gitconfig` (or the
   file selected by `MAKEPKG_GIT_CONFIG`). For a build user already authenticated
   with GitHub CLI, the administrator can configure that file with:

   ```gitconfig
   [credential "https://github.com"]
       helper =
       helper = !/usr/bin/gh auth git-credential
   ```

   This example requires `gh` on the builder and GitHub CLI credentials
   accessible to the build user. An existing noninteractive credential helper
   can be configured there instead. Test access as the build user with the same
   Git configuration and environment that Remora uses.
3. Import the source signing key into that user's GPG keyring, replacing the
   example account and path with your settings:

   ```sh
   sudo -u builder gpg --import /path/to/linux-devario/release-signing-key.pub
   ```

   The public source key does not replace the builder's own private
   package-signing key.

Remora runs `makepkg --verifysource --noconfirm`, followed by
`makepkg -sr --sign -f --noconfirm`, and collects both split packages using
`makepkg --packagelist`. These commands clone/update the source automatically.
The builder must support authentication, dependency installation, and signing
without interactive prompts. Shelly engine support for this private signed Git
source has not been validated.

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

This recipe does not switch Devario's default kernel. Its current boot helpers
still select `linux-cachyos-lts`; migrate those consumers as described in
`docs/NET-INSTALL-KERNEL-PLAN.md` before relying on automatic boot deployment of
this package. Do not remove the old working kernel during initial testing.

Before production publication, complete a full build, verify package contents,
compile NVIDIA DKMS against the headers, and test BIOS/UEFI boot, dracut
generation, and a kernel upgrade. Source verification and successful
configuration preparation alone do not establish those results.

Checked on 2026-09-27: Bash syntax, makepkg metadata, local source checksums,
Git tag signature, pinned commit, and `prepare()` from a Git checkout. Validation
used a shallow clone of the release tag with `makepkg --nobuild --nodeps
--holdver`; the resulting kernel release is `7.2.7-1-devario`, with GCC/BFD,
LTO disabled, x86-64-v3 selected, and Rust enabled. The earlier archive-based recipe also passed
`modules_prepare`. A full mirror download, Remora job, complete kernel/package
build, and boot/DKMS tests have not yet been run.

For an upstream update, change `_tag`, `_commit`, `_source_epoch`, `pkgver`,
and normalized config/checksum together; verify the new tag's signing key.
For a packaging-only rebuild, increment `pkgrel`; `_tag` remains unchanged.
Regenerate `.SRCINFO` with `makepkg --printsrcinfo > .SRCINFO`.
