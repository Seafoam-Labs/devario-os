#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Data is parsed, never sourced. Discovery is shared by generation and entries.
devario_kernel_discover() {
  local modules_root="$1" wanted_id="${2:-}" wanted_version="${3:-}"
  local tree key value release image identifier
  local -A fields=()
  local -A seen=()
  DEVARIO_KERNEL_IDS=() DEVARIO_KERNEL_VERSIONS=() DEVARIO_KERNEL_IMAGES=()
  for tree in "$modules_root"/*; do
    [[ -d "$tree" ]] || continue
    [[ -z "$wanted_version" || "${tree##*/}" == "$wanted_version" ]] || continue
    release= image= identifier= fields=()
    if [[ -f "$tree/devario-kernel" ]]; then
      while IFS='=' read -r key value; do
        [[ -n "$key" && -n "$value" && -z "${fields[$key]:-}" ]] || return 1
        case "$key" in
          version|image|id) fields[$key]="$value" ;;
          *) echo "Unknown Devario kernel metadata field: $key" >&2; return 1 ;;
        esac
      done < "$tree/devario-kernel"
      release="${fields[version]:-}" image="${fields[image]:-}" identifier="${fields[id]:-}"
      [[ "$release" == "${tree##*/}" && "$image" == vmlinuz ]] || return 1
    elif [[ -f "$tree/pkgbase" ]]; then
      # Repository compatibility adapter; native Devario kernels use metadata above.
      read -r identifier < "$tree/pkgbase"
      release="${tree##*/}" image=vmlinuz
    else
      continue
    fi
    [[ "$identifier" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ \
      && "$release" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || return 1
    [[ -z "$wanted_id" || "$identifier" == "$wanted_id" ]] || continue
    [[ -s "$tree/$image" ]] || { echo "Missing kernel image: $tree/$image" >&2; return 1; }
    if [[ -n "${seen[$identifier]:-}" ]]; then
      echo "Multiple installed versions of $identifier; refusing to overwrite the same boot files." >&2
      return 1
    fi
    seen[$identifier]=1
    DEVARIO_KERNEL_IDS+=("$identifier")
    DEVARIO_KERNEL_VERSIONS+=("$release")
    DEVARIO_KERNEL_IMAGES+=("$tree/$image")
  done
  if (( ${#DEVARIO_KERNEL_IDS[@]} == 0 )); then
    echo "No installed ${wanted_id:-bootable} kernel found below $modules_root." >&2
    return 1
  fi
}

devario_kernel_select() {
  devario_kernel_discover "$1" "$2" "${3:-}" || return 1
  DEVARIO_KERNEL_ID="${DEVARIO_KERNEL_IDS[0]}"
  DEVARIO_KERNEL_VERSION="${DEVARIO_KERNEL_VERSIONS[0]}"
  DEVARIO_KERNEL_IMAGE="${DEVARIO_KERNEL_IMAGES[0]}"
}
