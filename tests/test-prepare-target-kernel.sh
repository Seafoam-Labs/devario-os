#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
profile_dir="${DEVARIO_PROFILE_DIR:-$project_dir/archiso}"
helper="$profile_dir/airootfs/usr/lib/devario/prepare-target-kernel"
test_root="$(mktemp -d /tmp/devario-kernel-helper.XXXXXX)"

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

modules_root="$test_root/modules"
boot_root="$test_root/boot"
install -d \
  "$modules_root/6.18.42-test-cachyos-lts" \
  "$modules_root/unrelated" \
  "$boot_root"

printf '%s\n' linux-cachyos-lts \
  > "$modules_root/6.18.42-test-cachyos-lts/pkgbase"
printf '%s\n' devario-kernel \
  > "$modules_root/6.18.42-test-cachyos-lts/vmlinuz"
printf '%s\n' unrelated-kernel > "$modules_root/unrelated/pkgbase"
printf '%s\n' other-kernel > "$modules_root/unrelated/vmlinuz"

"$helper" "$modules_root" "$boot_root"
cmp \
  "$modules_root/6.18.42-test-cachyos-lts/vmlinuz" \
  "$boot_root/vmlinuz-linux-cachyos-lts"

printf '%s\n' linux-cachyos-lts > "$modules_root/unrelated/pkgbase"
if "$helper" "$modules_root" "$boot_root" >/dev/null 2>&1; then
  echo "The target-kernel helper accepted multiple matching module trees." >&2
  exit 1
fi

printf '%s\n' unrelated-kernel \
  > "$modules_root/6.18.42-test-cachyos-lts/pkgbase"
printf '%s\n' unrelated-kernel > "$modules_root/unrelated/pkgbase"
if "$helper" "$modules_root" "$boot_root" >/dev/null 2>&1; then
  echo "The target-kernel helper accepted a missing CachyOS LTS module tree." >&2
  exit 1
fi

echo "Target-kernel preparation tests passed."
