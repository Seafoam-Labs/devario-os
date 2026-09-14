# Devario Archiso bootstrap

Devario vendors the official Archiso v89 source archive and applies
`0001-bootstrap-with-shelly.patch`,
`0002-copy-late-airootfs-after-packages.patch`, and
`0003-verify-installed-packages.patch` at ISO build time. The patches retain
Archiso's image, bootloader, chroot-mount, and profile orchestration while
routing repository synchronization, target package installation, and package
inventory through Shelly. The first also rewrites the otherwise-unused stock CI
package setup and releng keyring service so the complete patched vendor tree
contains no Pacman-family executable call.

The second patch copies `late-airootfs` after package installation. Devario
uses that overlay for live-only sysusers and tmpfiles declarations so package
hooks cannot materialize `liveuser` in the SquashFS; systemd creates the user
only in the writable live-session overlay at boot.

The third patch closes a gap left by the first. Shelly currently returns
success when one or more explicitly requested packages are unavailable, so
after installation the transaction re-reads the target inventory with
`shelly list standard --show-hidden --json` and refuses a partial root
filesystem, naming every package it asked for and did not get. Without it the
shortfall would surface later, in a package hook or a boot image that cannot
start, with the cause obscured.

Source:
`https://gitlab.archlinux.org/archlinux/archiso/-/archive/v89/archiso-v89.tar.gz`

SHA-256:
`d4e98484aaa4880888765cdc8ee9bcabed98320c3e6372b5d9699e32d1a33040`

The archive contains Archiso's GPL-3.0-or-later license file.
