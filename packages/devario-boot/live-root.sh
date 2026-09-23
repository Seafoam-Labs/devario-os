#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
. /lib/dracut-lib.sh
image=$1
if [ -b "$image" ] && [ "$(blkid -s TYPE -o value "$image")" != squashfs ]; then
    mkdir -p /run/initramfs/live
    mountpoint -q /run/initramfs/live || mount -o ro "$image" /run/initramfs/live || exit 1
    image="/run/initramfs/live/$(getarg rd.live.dir)/$(getarg rd.live.squashimg)"
fi
[ -s "$image" ] || { die 'Devario live image is missing'; exit 1; }
if getargbool 0 rd.devario.verify; then
    signature="$image.cms.sig"
    source_url=$(getarg root=)
    case "$source_url" in
        live:http://*|live:https://*)
            signature=/run/initramfs/devario-live.cms.sig
            curl --fail --location --retry 3 --output "$signature" "${source_url#live:}.cms.sig" || exit 1 ;;
    esac
    /sbin/devario-verify-live-image "$image" "$signature" /etc/devario/live-signing.pem \
        || { die 'Devario live-image signature verification failed'; exit 1; }
fi
exec /sbin/devario-dmsquash-live-root "$image"
