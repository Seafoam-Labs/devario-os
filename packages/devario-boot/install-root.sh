#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# dracut 111 retains the pristine direct SquashFS at /run/rootfsbase.
# /run is carried across switch-root; Calamares never copies the writable overlay.
mkdir -p /run/devario/install-root
mount --bind /run/rootfsbase /run/devario/install-root || { die 'Cannot preserve Devario installation source'; return 1; }
mount -o remount,bind,ro /run/devario/install-root || { die 'Cannot protect Devario installation source'; return 1; }
: > /run/devario/live
if getargbool 0 rd.live.ram; then
    if mountpoint -q /run/initramfs/live; then
        umount /run/initramfs/live || { die 'Cannot release copied live media'; return 1; }
    fi
fi
