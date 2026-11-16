#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Ventoy exposes the ISO as /dev/mapper/ventoy, created by its injected runtime
# with a static dmsetup that predates udev cookies. 10-dm.rules then treats the
# device as a spurious activation and 13-dm-disk.rules never publishes
# by-uuid/by-label symlinks, so live:UUID=/LABEL= roots would wait forever.
# Mirror Ventoy's own distro hooks and retarget the live root at the mapper
# node: 10-dm.rules always creates the mapper/ symlink and
# dmsquash-live-genrules.sh triggers dmsquash-live-root from it without probing.
[ -e /ventoy/ventoy_os_param ] || return 0
case "$(getarg root=)" in
    live:UUID=* | live:LABEL=* | live:CDLABEL=* | live:PARTUUID=* | live:PARTLABEL=*) ;;
    *) return 0 ;;
esac
mkdir -p /run/initramfs/cmdline.d
# /run/initramfs/cmdline.d is appended after /proc/cmdline by getcmdline, and
# dracut-getarg keeps the last match, so this overrides the boot entry's root.
printf 'root=live:/dev/mapper/ventoy\n' > /run/initramfs/cmdline.d/99-ventoy.conf
root=live:/dev/mapper/ventoy
