#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Switch an existing installation to disk-backed /tmp on its next boot.
set -euo pipefail

if [[ $# -eq 1 && ( $1 == --help || $1 == -h ) ]]; then
  cat <<'EOF'
Usage: sudo bash scripts/use-disk-tmp.sh

Prevent systemd from mounting tmpfs at /tmp on the next boot. /tmp will
use the underlying root filesystem. Run this on the installed system.
The script does not unmount /tmp, delete files, or reboot the machine.
An explicit /tmp mount in /etc/fstab must be handled separately.
EOF
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo 'Unexpected argument. Use --help for usage.' >&2
  exit 2
fi
if [[ $(id -u) -ne 0 ]]; then
  echo 'Run this script with sudo to configure /etc/systemd/system/tmp.mount.' >&2
  exit 1
fi
if [[ -L /tmp ]]; then
  echo '/tmp is a symlink; inspect its destination before changing its mount policy.' >&2
  exit 1
fi

# Do not silently disable an explicitly configured separate /tmp filesystem.
# findmnt exits 1 when fstab has no entries.
if mounts=$(findmnt --fstab --raw --noheadings --output TARGET); then
  while IFS= read -r mountpoint; do
    if [[ $mountpoint == /tmp ]]; then
      echo '/etc/fstab explicitly mounts /tmp. Remove or adjust that entry first; no changes made.' >&2
      exit 1
    fi
  done <<< "$mounts"
else
  status=$?
  if [[ $status -ne 1 ]]; then
    echo 'Could not inspect /etc/fstab; no changes made.' >&2
    exit "$status"
  fi
fi

# No --now or --force: preserve the live mount and any custom unit file.
systemctl mask tmp.mount

cat <<'EOF'
Disk-backed /tmp is configured for the next boot.
The current /tmp mount and its files have not been changed.

Before rebooting, save your work and copy any files you need out of /tmp:
the current RAM-backed contents will be lost at reboot.
Reboot when ready: sudo reboot
Then verify: findmnt -T /tmp
It should show your disk filesystem (for example ext4 or btrfs), not tmpfs.

To restore the systemd default: sudo systemctl unmask tmp.mount
Then reboot again.
EOF
