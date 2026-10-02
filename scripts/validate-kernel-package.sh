#!/usr/bin/env bash
# Validate the pinned 7.2.7-1 recipe in its external source checkout.
set -euo pipefail
if (( $# != 1 )) || [[ "$1" == --help || "$1" == -h ]]; then
  echo 'Usage: validate-kernel-package.sh EXTERNAL-LINUX-DEVARIO-DIRECTORY'
  echo 'Checks the pinned linux-devario 7.2.7-1 recipe and configuration.'
  if (( $# == 1 )); then exit 0; else exit 2; fi
fi
kernel_source="$1"
for file in PKGBUILD config; do
  [[ -f "$kernel_source/$file" ]] || { echo "Missing kernel source: $kernel_source/$file" >&2; exit 1; }
done
failed=0
fail() { echo "Kernel validation error: $*" >&2; failed=1; }
if ! grep -Fqx 'pkgbase=linux-devario' "$kernel_source/PKGBUILD" \
  || ! grep -Fqx 'pkgname=(linux-devario linux-devario-headers)' "$kernel_source/PKGBUILD"; then
  fail 'recipe must declare the kernel and matching headers'
fi
kernel_pkgbuild="$kernel_source/PKGBUILD"
kernel_config="$kernel_source/config"
expected_kernel_config_sha256='061cb499b26c8290efc6d793f6eafba8d6960e38f758b9c6e109b7b5e61f2fa0'
actual_kernel_config_sha256="$(sha256sum "$kernel_config")"
actual_kernel_config_sha256="${actual_kernel_config_sha256%% *}"
if [[ "$actual_kernel_config_sha256" != "$expected_kernel_config_sha256" ]]; then
  fail "linux-devario/config failed its pinned SHA-256 checksum"
fi
for required_kernel_recipe_text in \
  '_tag=devario-7.2.7-1' \
  '_commit=00a4b3afc99f9413ff9ad168c2fdbe3f788eb9e5' \
  'pkgver=7.2.7' \
  'pkgrel=1' \
  'CONFIG_GENERIC_CPU=y CONFIG_X86_64_VERSION=3' \
  'CONFIG_CC_IS_GCC=y CONFIG_LD_IS_BFD=y' \
  'CONFIG_LTO_NONE=y CONFIG_RUST=y' \
  'KBUILD_BUILD_HOST=devario' \
  '399521CE9D6D65B35EEF0F8C79AFA05ABDB26C5A' \
  'ded1d9a0826e6c2cbf707467a30fb38e8ca3e9a95f74072abef3a44be238a29f' \
  '"$modulesdir/devario-kernel"' \
  'package_linux-devario-headers()' \
  '"linux-devario=$pkgver-$pkgrel"' \
  "$expected_kernel_config_sha256"; do
  if ! grep -Fq "$required_kernel_recipe_text" "$kernel_pkgbuild"; then
    fail "linux-devario packaging is missing: $required_kernel_recipe_text"
  fi
done
for kernel_setting in CONFIG_GENERIC_CPU=y CONFIG_X86_64_VERSION=3 \
  CONFIG_LTO_NONE=y CONFIG_RUST=y CONFIG_BLK_DEV_INITRD=y CONFIG_EFI_STUB=y \
  CONFIG_SQUASHFS=m CONFIG_OVERLAY_FS=m CONFIG_BLK_DEV_LOOP=m; do
  if ! grep -Fxq "$kernel_setting" "$kernel_config"; then
    fail "linux-devario/config is missing: $kernel_setting"
  fi
done
if grep -Eq "^[[:space:]]*['\"]?SKIP['\"]?([[:space:]]|$)" "$kernel_pkgbuild"; then
  fail "linux-devario must use pinned sources"
fi

exit "$failed"
