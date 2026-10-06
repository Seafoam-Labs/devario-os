#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"; check="$project_dir/iso/airootfs/usr/lib/devario/acceptance-self-check"
service="$project_dir/iso/airootfs/etc/systemd/system/devario-acceptance-self-check.service"
root="$(mktemp -d /tmp/devario-self-check-test.XXXXXX)"; trap 'rm -rf -- "$root"' EXIT
mkdir -p "$root/etc" "$root/var/lib/devario"; printf 'machine-id\n' > "$root/etc/machine-id"; printf '/dev/root / ext4 defaults 0 1\n' > "$root/etc/fstab"; : > "$root/var/lib/devario/shelly-keyring.ready"
write_os_release() { printf 'ID=devario\nVARIANT_ID=%s\n' "$1" > "$root/etc/os-release"; }
write_core_shelly() {
  local server="${1:-https://packages.devario.example/core/\$arch}" repository
  printf '%s\n' '[options]' 'SigLevel = Never' '[devario-core]' 'SigLevel = Required' "Server = $server" > "$root/etc/shelly.conf"
  for repository in devario-browser devario-development devario-entertainment devario-gaming devario-utilities devario-productivity devario-scx; do
    printf '\n[%s]\nSigLevel = Required\nServer = https://mirrors.seafoam-labs.org/%s/$arch\n' \
      "$repository" "$repository" >> "$root/etc/shelly.conf"
  done
}
mkdir -p "$root/boot/loader/entries" "$root/boot/EFI/systemd" "$root/boot/EFI/BOOT"
: > "$root/var/lib/devario/systemd-boot-installed"
for file in loader/entries/devario.conf loader/entries/devario-fallback.conf EFI/systemd/systemd-bootx64.efi EFI/BOOT/BOOTX64.EFI; do printf 'boot fixture\n' > "$root/boot/$file"; done
write_os_release community; write_core_shelly
if "$check" --root "$root" --mode installed --firmware bios --edition community >/dev/null 2>&1; then echo 'Installed BIOS unexpectedly accepted.' >&2; exit 1; fi
output="$($check --root "$root" --mode installed --firmware uefi --edition community)"
[[ "$output" == 'DEVARIO_ACCEPTANCE:PASS mode=installed firmware=uefi edition=community' ]] || { echo 'Valid Community self-check did not pass.' >&2; exit 1; }
grep -Fqx 'Requires=shelly-keyring-init.service' "$service" || { echo 'Acceptance service does not require successful keyring initialization.' >&2; exit 1; }
grep -Eq '^After=.*\bshelly-keyring-init\.service\b' "$service" || { echo 'Acceptance service is not ordered after keyring initialization.' >&2; exit 1; }
! grep -Fqx 'Requires=shelly-storage-migrate.service' "$project_dir/iso/airootfs/etc/systemd/system/shelly-keyring-init.service" || { echo 'Keyring initialization must not relocate RLPM state.' >&2; exit 1; }
rm -f "$root/var/lib/devario/shelly-keyring.ready"
if "$check" --root "$root" --mode installed --firmware uefi --edition community >/dev/null 2>&1; then echo 'Self-check passed without the keyring-ready marker.' >&2; exit 1; fi
: > "$root/var/lib/devario/shelly-keyring.ready"

rule="$root/etc/polkit-1/rules.d/49-devario-live-installer.rules"
if "$check" --root "$root" --mode live --firmware bios --edition community >/dev/null 2>&1; then echo 'Live image passed without installer authorization.' >&2; exit 1; fi
mkdir -p "$(dirname "$rule")"
cp "$project_dir/iso/airootfs/etc/polkit-1/rules.d/49-devario-live-installer.rules" "$rule"
"$check" --root "$root" --mode live --firmware bios --edition community >/dev/null
if "$check" --root "$root" --mode installed --firmware uefi --edition community >/dev/null 2>&1; then echo 'Installed image retained live installer authorization.' >&2; exit 1; fi
rm "$rule"
mkdir -p "$root/usr/lib/devario"
touch "$root/usr/lib/devario/start-installer"
if "$check" --root "$root" --mode installed --firmware uefi --edition community >/dev/null 2>&1; then echo 'Installed image retained the live installer launcher.' >&2; exit 1; fi
rm "$root/usr/lib/devario/start-installer"

for repository in devario-browser devario-development devario-entertainment devario-gaming devario-utilities devario-productivity devario-scx; do
  write_core_shelly
  sed -i "/^\[$repository\]$/,/^$/d" "$root/etc/shelly.conf"
  if "$check" --root "$root" --mode installed --firmware uefi --edition community >/dev/null 2>&1; then
    echo "Self-check passed without $repository." >&2; exit 1
  fi
done
write_core_shelly
sed -i '/^\[options\]$/,/^\[/s/SigLevel = Never/SigLevel = Required/; /^\[devario-core\]$/,/^$/ { /SigLevel = Required/d; }' "$root/etc/shelly.conf"
if "$check" --root "$root" --mode installed --firmware uefi --edition community >/dev/null 2>&1; then echo 'Global SigLevel incorrectly satisfied the repository requirement.' >&2; exit 1; fi
write_core_shelly; sed -i 's#https://packages#https://user:password@packages#' "$root/etc/shelly.conf"
if "$check" --root "$root" --mode installed --firmware uefi --edition community >/dev/null 2>&1; then echo 'Credential-bearing repository URL was accepted.' >&2; exit 1; fi
for unsafe_suffix in '?token=value' '#fragment' '\\escaped'; do
  write_core_shelly "https://packages.devario.example/core/\$arch$unsafe_suffix"
  if "$check" --root "$root" --mode installed --firmware uefi --edition community >/dev/null 2>&1; then
    echo "Unsafe repository URL suffix was accepted: $unsafe_suffix" >&2
    exit 1
  fi
done
write_core_shelly; printf '%s\n' 'Server = https://second.devario.example/core/' >> "$root/etc/shelly.conf"
if "$check" --root "$root" --mode installed --firmware uefi --edition community >/dev/null 2>&1; then echo 'Duplicate repository Server was accepted.' >&2; exit 1; fi

write_os_release managed; write_core_shelly
if "$check" --root "$root" --mode installed --firmware uefi --edition managed >/dev/null 2>&1; then echo 'Managed image passed without managed repository trust.' >&2; exit 1; fi
printf '%s\n' '[devario-managed]' 'SigLevel = Required' 'Server = https://packages.devario.example/managed/$arch' >> "$root/etc/shelly.conf"
"$check" --root "$root" --mode installed --firmware uefi --edition managed >/dev/null
echo 'Acceptance self-check tests passed.'
