#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Data is parsed, never sourced. Callers may select a version explicitly.
devario_kernel_select() {
  local modules_root="$1" wanted_id="$2" wanted_version="${3:-}"
  local tree key value release image identifier count=0
  local -A fields=()
  shopt -s nullglob
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
    [[ "$identifier" == "$wanted_id" ]] || continue
    [[ -s "$tree/$image" ]] || { echo "Missing kernel image: $tree/$image" >&2; return 1; }
    DEVARIO_KERNEL_VERSION="$release"
    DEVARIO_KERNEL_IMAGE="$tree/$image"
    DEVARIO_KERNEL_ID="$identifier"
    (( count += 1 ))
  done
  if (( count != 1 )); then
    echo "Expected exactly one $wanted_id kernel below $modules_root; found $count." >&2
    return 1
  fi
}
