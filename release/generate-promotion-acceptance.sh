#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; source "$script_dir/lib-release.sh"
candidate='' disk='' format='' lock='' review='' review_sig='' output=''
declare -A result_files=() log_files=()
while (( $# )); do
  case "$1" in
    --candidate) candidate="$2"; shift 2;; --installed-disk) disk="$2"; shift 2;; --disk-format) format="$2"; shift 2;;
    --installation-lock) lock="$2"; shift 2;; --installation-review) review="$2"; shift 2;; --review-signature) review_sig="$2"; shift 2;; --output) output="$2"; shift 2;;
    --live-bios-result) result_files[live-bios]="$2"; shift 2;; --live-bios-log) log_files[live-bios]="$2"; shift 2;;
    --live-uefi-result) result_files[live-uefi]="$2"; shift 2;; --live-uefi-log) log_files[live-uefi]="$2"; shift 2;;
    --installed-uefi-result) result_files[installed-uefi]="$2"; shift 2;; --installed-uefi-log) log_files[installed-uefi]="$2"; shift 2;;
    *) echo 'Usage: generate-promotion-acceptance.sh --candidate LOCK --installed-disk DISK --disk-format raw|qcow2 --installation-lock FILE --installation-review FILE --review-signature FILE --live-bios-result FILE --live-bios-log FILE --live-uefi-result FILE --live-uefi-log FILE --installed-uefi-result FILE --installed-uefi-log FILE --output DIR' >&2; exit 2;;
  esac
done
for value in candidate disk format lock review review_sig output; do [[ -n "${!value}" ]] || exit 2; done
[[ "$format" == raw || "$format" == qcow2 ]] || exit 2
[[ ! -e "$output" ]] || { echo 'Acceptance evidence output already exists.' >&2; exit 1; }
for pair in live-bios live-uefi installed-uefi; do
  [[ -n "${result_files[$pair]:-}" && -n "${log_files[$pair]:-}" ]] || { echo "Missing $pair evidence." >&2; exit 2; }
  [[ "$(basename -- "${result_files[$pair]}")" == "$pair.json" && "$(basename -- "${log_files[$pair]}")" == "$pair.log" ]] || {
    echo "Acceptance inputs must already use canonical names $pair.json and $pair.log." >&2; exit 1;
  }
done
for file in "$candidate" "$disk" "$lock" "$review" "$review_sig" "${result_files[@]}" "${log_files[@]}"; do [[ -f "$file" && ! -L "$file" ]] || { echo "Evidence is not a regular file: $file" >&2; exit 1; }; done
temporary="$(mktemp -d /tmp/devario-promotion-acceptance.XXXXXX)"; trap 'rm -rf -- "$temporary"' EXIT
install -m 0444 "$disk" "$temporary/installed.$format"
install -m 0444 "$lock" "$temporary/installation-lock.json"; install -m 0444 "$review" "$temporary/installation-review.json"; install -m 0444 "$review_sig" "$temporary/installation-review.json.sig"
for pair in live-bios live-uefi installed-uefi; do install -m 0444 "${result_files[$pair]}" "$temporary/$pair.json"; install -m 0444 "${log_files[$pair]}" "$temporary/$pair.log"; done
file_json() { jq -cn --arg path "$1" --arg sha256 "$(devario_sha256 "$temporary/$1")" --argjson size "$(stat -c '%s' "$temporary/$1")" '{path:$path,sha256:$sha256,size:$size}'; }
: > "$temporary/results.jsonl"
for pair in live-bios live-uefi installed-uefi; do
  mode="${pair%-*}"; firmware="${pair#*-}"
  jq -cn --arg mode "$mode" --arg firmware "$firmware" --argjson document "$(file_json "$pair.json")" --argjson log "$(file_json "$pair.log")" '{mode:$mode,firmware:$firmware,document:$document,log:$log}' >> "$temporary/results.jsonl"
done
jq -s '.' "$temporary/results.jsonl" > "$temporary/results.json"
jq -n --arg candidate "$(devario_sha256 "$candidate")" --arg candidateVersion "$(jq -r '.version' "$candidate")" --arg edition "$(jq -r '.edition' "$candidate")" --arg format "$format" \
  --argjson disk "$(file_json "installed.$format")" --argjson lock "$(file_json installation-lock.json)" \
  --argjson review "$(file_json installation-review.json)" --argjson signature "$(file_json installation-review.json.sig)" \
  --slurpfile results "$temporary/results.json" '{schemaVersion:2,candidateSha256:$candidate,candidateVersion:$candidateVersion,edition:$edition,diskFormat:$format,installedDisk:$disk,installationLock:$lock,installationReview:{document:$review,signature:$signature},results:$results[0]}' > "$temporary/promotion-acceptance.json"
rm -f -- "$temporary/results.json" "$temporary/results.jsonl"
python3 "$script_dir/validate-json.py" "$script_dir/promotion-acceptance.schema.json" "$temporary/promotion-acceptance.json"
(cd "$temporary" && find . -maxdepth 1 -type f ! -name ACCEPTANCE.SHA256SUMS -printf '%f\0' | sort -z | xargs -0 sha256sum -- > ACCEPTANCE.SHA256SUMS)
find "$temporary" -maxdepth 1 -type f -exec chmod 0444 {} +
mv -- "$temporary" "$output"; trap - EXIT
echo "Finalized closed promotion evidence: $output"
