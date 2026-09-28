# Shelly for Devario

This recipe builds `shelly` **3.1.6-1**, pinned to upstream release `v3.1.6`,
commit `d9d89773968a5a03beb5183c1101e0235e4f3524`. It keeps the package name
`shelly` so existing Devario dependencies and upgrade transactions select it.
The source archive and all patches have SHA-256 checksums; `prepare()` applies
the patches in order with fuzz disabled.

## Distribution patches

| Patch | Purpose |
| --- | --- |
| `0001-remove-pacman-runtime-processes.patch` | Use `/usr/bin/shelly-key` for keyring/repository actions and read package ownership directly from the selected ALPM database instead of running `pacman -Qoq`. Includes updated ownership/keyring tests. |
| `0002-support-alternate-alpm-config.patch` | Honor `SHELLY_ALPM_CONFIG` when no explicit configuration path is supplied. An explicit path still takes precedence. |
| `0003-use-shelly-runtime-paths.patch` | Use `/etc/shelly.conf`, `/var/lib/shelly`, `/var/cache/shelly/pkg`, and `/etc/shelly.d/{gnupg,hooks}`; adapt CLI, native builder, keyring, bootstrap, UI, and tests. Preserve the restriction on `shelly build --isolated` until its new upstream provisioning is assessed for Devario. |

Upstream 3.1.6 already implements native keyring and bootstrap operations; the
patches are rebased onto that implementation. Arch-compatible trust-root and
mirrorlist locations remain where required by existing packages. The runtime
package owns `/etc/shelly.conf` and the storage migration; this recipe owns
`/etc/shellybuild.conf` and preserves administrator changes to it.

The package depends on `devario-alpm-runtime>=7.1.0.r9.g54d9411-2` and the
`libalpm.so.16` ABI, rather than the executable Pacman package. It installs the
CLI, GTK UI, native keyring helper, notifications, completions, manual page,
translations, desktop entries, and Polkit policy. Flatpak support remains an
optional backend package.

## Remora inputs

Name the package **`shelly`** and upload these files at one level:

```text
PKGBUILD
0001-remove-pacman-runtime-processes.patch
0002-support-alternate-alpm-config.patch
0003-use-shelly-runtime-paths.patch
```

The recipe downloads the pinned upstream archive automatically. `.SRCINFO` and
this README are optional metadata/documentation; do not upload local `src/`,
cached archives, or build outputs. Use Remora's Makepkg engine. The resulting
Devario binary deliberately rejects isolated builds, including the isolated
mode used by Remora's Shelly engine.

The builder must have access to a repository supplying `devario-alpm-runtime`
and the declared dependencies, including Zig 0.16 or newer. Zig also fetches
dependencies pinned by upstream's build manifests. Configure package signing
on the builder before publication.

## Devario build path

With build dependencies already installed through Shelly, run from this directory:

```sh
devario_project=$(realpath ../..)
export DEVARIO_MAKEPKG_PKGDEST="$devario_project/work/shelly/packages"
export DEVARIO_MAKEPKG_SRCPKGDEST="$devario_project/work/shelly/sources"
export DEVARIO_MAKEPKG_BUILDDIR="$devario_project/work/shelly/build"
mkdir -p "$DEVARIO_MAKEPKG_PKGDEST" "$DEVARIO_MAKEPKG_SRCPKGDEST" \
  "$DEVARIO_MAKEPKG_BUILDDIR"
export PACMAN="$devario_project/scripts/makepkg-shelly-adapter.sh"
makepkg --config "$devario_project/scripts/makepkg-shelly.conf" \
  --nodeps --cleanbuild
```

This adapter supplies makepkg's read-only build inventory; Shelly handles
dependency installation. `check()` runs upstream CLI, keyring, and package
manager tests, including the patched behavior. Do not disable checks for release
builds. Sign and publish the package through the normal repository process;
roll it out with the coordinated netinstall migration after installer and
desktop acceptance testing.

## Validation on 2026-09-27

Source and patch checksums passed, and all patches applied with zero fuzz.
The full makepkg build produced `shelly-3.1.6-1-x86_64.pkg.tar.zst`; artifact
inspection confirmed the expected executables, Devario runtime dependency,
`libalpm.so.16` linkage, and `/etc/shellybuild.conf` backup entry. The test
artifact is unsigned and has not been installed or published.

CLI tests: 411 passed. Keyring tests: 147 passed. Package-manager tests:
1,371 passed and 4 skipped. Shelly-specific repository policy checks passed.
Full repository validation still reports unrelated missing vendored dracut
source, outdated CachyOS pins, and the existing Pacman call in dracut-install.
Installer, desktop, and release acceptance remain part of the netinstall work.
