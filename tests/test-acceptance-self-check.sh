#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"; check="$project_dir/archiso/airootfs/usr/lib/devario/acceptance-self-check"
service="$project_dir/archiso/airootfs/etc/systemd/system/devario-acceptance-self-check.service"
root="$(mktemp -d /tmp/devario-self-check-test.XXXXXX)"; trap 'rm -rf -- "$root"' EXIT
mkdir -p "$root/etc" "$root/var/lib/devario"; printf 'machine-id\n' > "$root/etc/machine-id"; printf '/dev/root / ext4 defaults 0 1\n' > "$root/etc/fstab"; : > "$root/var/lib/devario/shelly-keyring.ready"
write_os_release() { printf 'ID=devario\nVARIANT_ID=%s\n' "$1" > "$root/etc/os-release"; }
write_core_shelly() {
  local server="${1:-https://packages.devario.example/core/\$arch}"
  printf '%s\n' '[options]' 'SigLevel = Never' '[devario-core]' 'SigLevel = Required' "Server = $server" '[core]' 'Include = /etc/pacman.d/mirrorlist' > "$root/etc/shelly.conf"
}
write_os_release community; write_core_shelly
output="$($check --root "$root" --mode installed --firmware bios --edition community)"
[[ "$output" == 'DEVARIO_ACCEPTANCE:PASS mode=installed firmware=bios edition=community' ]] || { echo 'Valid Community self-check did not pass.' >&2; exit 1; }
grep -Fqx 'Requires=shelly-keyring-init.service' "$service" || { echo 'Acceptance service does not require successful keyring initialization.' >&2; exit 1; }
grep -Eq '^After=.*\bshelly-keyring-init\.service\b' "$service" || { echo 'Acceptance service is not ordered after keyring initialization.' >&2; exit 1; }
grep -Fqx 'Requires=shelly-storage-migrate.service' "$project_dir/archiso/airootfs/etc/systemd/system/shelly-keyring-init.service" || { echo 'Keyring initialization does not require Shelly storage migration.' >&2; exit 1; }
rm -f "$root/var/lib/devario/shelly-keyring.ready"
if "$check" --root "$root" --mode installed --firmware bios --edition community >/dev/null 2>&1; then echo 'Self-check passed without the keyring-ready marker.' >&2; exit 1; fi
: > "$root/var/lib/devario/shelly-keyring.ready"

printf '%s\n' '[options]' 'SigLevel = Required' '[devario-core]' 'Server = https://packages.devario.example/core/' > "$root/etc/shelly.conf"
if "$check" --root "$root" --mode installed --firmware bios --edition community >/dev/null 2>&1; then echo 'Global SigLevel incorrectly satisfied the repository requirement.' >&2; exit 1; fi
write_core_shelly; sed -i 's#https://packages#https://user:password@packages#' "$root/etc/shelly.conf"
if "$check" --root "$root" --mode installed --firmware bios --edition community >/dev/null 2>&1; then echo 'Credential-bearing repository URL was accepted.' >&2; exit 1; fi
for unsafe_suffix in '?token=value' '#fragment' '\\escaped'; do
  write_core_shelly "https://packages.devario.example/core/\$arch$unsafe_suffix"
  if "$check" --root "$root" --mode installed --firmware bios --edition community >/dev/null 2>&1; then
    echo "Unsafe repository URL suffix was accepted: $unsafe_suffix" >&2
    exit 1
  fi
done
write_core_shelly; sed -i '/^\[core\]/i Server = https://second.devario.example/core/' "$root/etc/shelly.conf"
if "$check" --root "$root" --mode installed --firmware bios --edition community >/dev/null 2>&1; then echo 'Duplicate repository Server was accepted.' >&2; exit 1; fi

write_os_release managed; write_core_shelly
if "$check" --root "$root" --mode installed --firmware bios --edition managed >/dev/null 2>&1; then echo 'Managed image passed without managed repository trust.' >&2; exit 1; fi
printf '%s\n' '[devario-managed]' 'SigLevel = Required' 'Server = https://packages.devario.example/managed/$arch' >> "$root/etc/shelly.conf"
"$check" --root "$root" --mode installed --firmware bios --edition managed >/dev/null
echo 'Acceptance self-check tests passed.'
