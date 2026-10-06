#!/usr/bin/env bash
# Shared requirements for Aqueous's Vulkan renderer in QEMU.

devario_qemu_check_venus() {
  local options summary property
  options="$(qemu-system-x86_64 -device virtio-vga-gl,help 2>&1)" || {
    echo 'QEMU must provide the virtio-vga-gl device.' >&2
    return 1
  }
  for property in venus blob hostmem; do
    if ! grep -Eq "^[[:space:]]*$property=" <<< "$options"; then
      echo "QEMU virtio-vga-gl lacks $property; install a QEMU build with Venus support." >&2
      return 1
    fi
  done
  command -v vulkaninfo >/dev/null 2>&1 || {
    echo 'vulkaninfo is required; install vulkan-tools through Shelly.' >&2
    return 1
  }
  if ! summary="$(LC_ALL=C timeout 20s vulkaninfo --summary 2>&1)" \
    || ! grep -Eq '^[[:space:]]*deviceName[[:space:]]*=' <<< "$summary"; then
    printf '%s\n' "$summary" >&2
    echo 'Host Vulkan enumeration failed; configure a working host Vulkan driver before booting Aqueous.' >&2
    return 1
  fi
}
