#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
profile_dir="${DEVARIO_PROFILE_DIR:-$project_dir/iso}"
source "$project_dir/packages/devario-boot/kernel.sh"
helper() {
  devario_kernel_select "$1" linux-devario || return
  install -Dm644 "$DEVARIO_KERNEL_IMAGE" "$2/vmlinuz-linux-devario"
}
test_root="$(mktemp -d /tmp/devario-kernel-helper.XXXXXX)"

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

modules_root="$test_root/modules"
boot_root="$test_root/boot"
install -d \
  "$modules_root/7.2.7-1-devario" \
  "$modules_root/unrelated" \
  "$boot_root"

printf '%s\n' linux-devario \
  > "$modules_root/7.2.7-1-devario/pkgbase"
printf '%s\n' devario-kernel \
  > "$modules_root/7.2.7-1-devario/vmlinuz"
printf '%s\n' linux-cachyos-lts > "$modules_root/unrelated/pkgbase"
printf '%s\n' other-kernel > "$modules_root/unrelated/vmlinuz"

helper "$modules_root" "$boot_root"
cmp \
  "$modules_root/7.2.7-1-devario/vmlinuz" \
  "$boot_root/vmlinuz-linux-devario"

printf '%s\n' linux-devario > "$modules_root/unrelated/pkgbase"
if helper "$modules_root" "$boot_root" >/dev/null 2>&1; then
  echo "The target-kernel helper accepted multiple matching module trees." >&2
  exit 1
fi

printf '%s\n' unrelated-kernel \
  > "$modules_root/7.2.7-1-devario/pkgbase"
printf '%s\n' linux-cachyos-lts > "$modules_root/unrelated/pkgbase"
if helper "$modules_root" "$boot_root" >/dev/null 2>&1; then
  echo "The target-kernel helper accepted a missing Devario module tree." >&2
  exit 1
fi

echo "Target-kernel preparation tests passed."
