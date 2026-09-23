#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="${DEVARIO_EDITION_ISO_NAME:-devario}"
iso_label="${DEVARIO_EDITION_ISO_LABEL_PREFIX:-DEVARIO}_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="${DEVARIO_EDITION_ISO_PUBLISHER:-Devario Project}"
iso_application="${DEVARIO_EDITION_ISO_APPLICATION:-Devario Live and Installation Medium}"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="devario"
buildmodes=('iso')
bootmodes=(
  'bios.syslinux'
  'uefi.systemd-boot'
)
pacman_conf="${DEVARIO_SHELLY_CONF:-shelly.build.conf}"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/polkit-1/rules.d/49-devario-live-installer.rules"]="0:0:644"
  ["/etc/sudoers.d/10-devario-live"]="0:0:440"
  ["/usr/lib/devario/prepare-target-kernel"]="0:0:755"
  ["/usr/local/bin/devario-aqueous-live-session"]="0:0:755"
)
