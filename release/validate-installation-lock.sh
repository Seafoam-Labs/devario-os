#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; source "$script_dir/lib-release.sh"
lock='' candidate='' source_image='' disk=''
while (( $# )); do case "$1" in --lock) lock="$2"; shift 2;; --candidate) candidate="$2"; shift 2;; --source-image) source_image="$2"; shift 2;; --disk) disk="$2"; shift 2;; *) exit 2;; esac; done
for value in lock candidate source_image disk; do [[ -n "${!value}" ]] || exit 2; done
for file in "$lock" "$candidate" "$source_image" "$disk"; do [[ -f "$file" && ! -L "$file" ]] || { echo "Unsafe installation evidence: $file" >&2; exit 1; }; done
python3 "$script_dir/validate-json.py" "$script_dir/candidate-lock.schema.json" "$candidate"
python3 "$script_dir/validate-json.py" "$script_dir/installation-lock.schema.json" "$lock"
source_artifact="$(devario_candidate_artifact_path "$candidate" "$source_image")" || { echo 'Installation source is not one unambiguous exact candidate artifact.' >&2; exit 1; }
jq -e --arg candidate "$(devario_sha256 "$candidate")" --arg candidateVersion "$(jq -r '.version' "$candidate")" --arg edition "$(jq -r '.edition' "$candidate")" --arg sourceName "$source_artifact" \
  --arg sourceSha "$(devario_sha256 "$source_image")" --argjson sourceSize "$(stat -c '%s' "$source_image")" \
  --arg diskName "$(basename -- "$disk")" --arg diskSha "$(devario_sha256 "$disk")" --argjson diskSize "$(stat -c '%s' "$disk")" '
  .candidateSha256==$candidate and .candidateVersion==$candidateVersion and .edition==$edition and .sourceImage=={name:$sourceName,sha256:$sourceSha,size:$sourceSize} and
  .installedDisk.name==$diskName and .installedDisk.sha256==$diskSha and .installedDisk.size==$diskSize
  ' "$lock" >/dev/null || { echo 'Installation lock does not bind the supplied candidate/image/disk.' >&2; exit 1; }
if [[ "$(jq -r '.installedDisk.format' "$lock")" == qcow2 ]]; then
  qemu-img info --output=json "$disk" | jq -e '.format == "qcow2" and (."backing-filename" // null) == null and (."data-file" // null) == null' >/dev/null || {
    echo 'Installed qcow2 is not self-contained.' >&2; exit 1;
  }
fi
echo 'Validated exact Calamares installation disk lock.'
