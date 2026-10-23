#!/usr/bin/env bash
# Create links to package-provided files only in the staged image profile.
set -euo pipefail

profile_dir="${1:?Usage: stage-image-links.sh STAGED_PROFILE}"
install -d -- "$profile_dir/airootfs/etc/calamares" \
  "$profile_dir/late-airootfs/etc/systemd/system/bluetooth.target.wants" \
  "$profile_dir/late-airootfs/etc/systemd/system/multi-user.target.wants" \
  "$profile_dir/late-airootfs/etc/systemd/system/graphical.target.wants"

ln -sT -- /usr/share/calamares/qml "$profile_dir/airootfs/etc/calamares/qml"
if [[ ! -e "$profile_dir/airootfs/etc/localtime" && ! -L "$profile_dir/airootfs/etc/localtime" ]]; then
  ln -sT -- ../usr/share/zoneinfo/UTC "$profile_dir/airootfs/etc/localtime"
fi
ln -sT -- ../../../../usr/lib/systemd/system/ufw.service \
  "$profile_dir/late-airootfs/etc/systemd/system/multi-user.target.wants/ufw.service"
ln -sT -- ../../../../usr/lib/systemd/system/bluetooth.service \
  "$profile_dir/late-airootfs/etc/systemd/system/bluetooth.target.wants/bluetooth.service"
ln -sT -- ../../../usr/lib/systemd/system/bluetooth.service \
  "$profile_dir/late-airootfs/etc/systemd/system/dbus-org.bluez.service"
ln -sT -- ../../../../usr/lib/systemd/system/devario-gpu-hotplug.service \
  "$profile_dir/late-airootfs/etc/systemd/system/multi-user.target.wants/devario-gpu-hotplug.service"
ln -sT -- ../../../../usr/lib/systemd/system/scx.service \
  "$profile_dir/late-airootfs/etc/systemd/system/multi-user.target.wants/scx.service"
ln -sT -- ../../../../usr/lib/systemd/system/upower.service \
  "$profile_dir/late-airootfs/etc/systemd/system/graphical.target.wants/upower.service"
