#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
check() { return 255; }
depends() { echo 'dmsquash-live livenet'; }
install() {
  inst_multiple mount mountpoint umount findmnt openssl curl
  # The live root must wait for its backing device even when dracut is staged
  # without the distribution's host-side initrd.target.wants symlinks.
  $SYSTEMCTL -q --root "$initdir" add-wants initrd.target dracut-initqueue.service
  # Wrap the pinned upstream implementation to enforce live-image verification.
  mv "$initdir/sbin/dmsquash-live-root" "$initdir/sbin/devario-dmsquash-live-root"
  inst_script "$moddir/live-root.sh" /sbin/dmsquash-live-root
  inst_script "$moddir/verify-live-image" /sbin/devario-verify-live-image
  inst_hook pre-pivot 90 "$moddir/install-root.sh"
  [[ ! -f /etc/devario/live-signing.pem ]] || inst_simple /etc/devario/live-signing.pem
}
