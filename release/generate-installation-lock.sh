#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; source "$script_dir/lib-release.sh"
candidate='' source_image='' disk='' format='' output=''
while (( $# )); do
  case "$1" in
    --candidate) candidate="$2"; shift 2 ;;
    --source-image) source_image="$2"; shift 2 ;;
    --disk) disk="$2"; shift 2 ;;
    --disk-format) format="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    *) echo 'Usage: generate-installation-lock.sh --candidate FILE --source-image ISO --disk FILE --disk-format raw|qcow2 --output FILE' >&2; exit 2 ;;
  esac
done
for value in candidate source_image disk format output; do [[ -n "${!value}" ]] || exit 2; done
[[ "$format" == raw || "$format" == qcow2 ]] || exit 2
for file in "$candidate" "$source_image" "$disk"; do [[ -f "$file" && ! -L "$file" ]] || { echo "Not a regular file: $file" >&2; exit 1; }; done
[[ ! -e "$output" ]] || { echo 'Installation lock output already exists.' >&2; exit 1; }
python3 "$script_dir/validate-json.py" "$script_dir/candidate-lock.schema.json" "$candidate"
source_artifact="$(devario_candidate_artifact_path "$candidate" "$source_image")" || {
  echo 'Installation source is not one unambiguous exact candidate artifact.' >&2
  exit 1
}
if [[ "$format" == qcow2 ]]; then
  qemu-img info --output=json "$disk" | jq -e '.format == "qcow2" and (."backing-filename" // null) == null and (."data-file" // null) == null' >/dev/null || {
    echo 'Installed qcow2 must be self-contained and have no backing/data file.' >&2; exit 1;
  }
fi
created="${DEVARIO_INSTALLATION_LOCK_TIME:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
temporary="$(mktemp /tmp/devario-installation-lock.XXXXXX)"; trap 'rm -f -- "$temporary"' EXIT
jq -n --arg candidate "$(devario_sha256 "$candidate")" --arg candidateVersion "$(jq -r '.version' "$candidate")" --arg edition "$(jq -r '.edition' "$candidate")" \
  --arg sourceName "$source_artifact" --arg sourceSha "$(devario_sha256 "$source_image")" --argjson sourceSize "$(stat -c '%s' "$source_image")" \
  --arg diskName "$(basename -- "$disk")" --arg diskSha "$(devario_sha256 "$disk")" --argjson diskSize "$(stat -c '%s' "$disk")" \
  --arg format "$format" --arg created "$created" '
  {schemaVersion:1,candidateSha256:$candidate,candidateVersion:$candidateVersion,edition:$edition,installer:"calamares",
   sourceImage:{name:$sourceName,sha256:$sourceSha,size:$sourceSize},
   installedDisk:{name:$diskName,sha256:$diskSha,size:$diskSize,format:$format},createdAt:$created}' > "$temporary"
python3 "$script_dir/validate-json.py" "$script_dir/installation-lock.schema.json" "$temporary"
install -m 0444 "$temporary" "$output"
echo "Locked exact installed disk: $output"
