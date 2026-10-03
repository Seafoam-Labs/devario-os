#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; source "$script_dir/lib-release.sh"
manifest='' evidence='' candidate='' source_image=''; policy="$script_dir/approval-trust-policy.json"; keyring="$script_dir/approval-keyring/release-approvers.gpg"
while (( $# )); do case "$1" in --manifest) manifest="$2"; shift 2;; --evidence-dir) evidence="$2"; shift 2;; --candidate) candidate="$2"; shift 2;; --source-image) source_image="$2"; shift 2;; --trust-policy) policy="$2"; shift 2;; --keyring) keyring="$2"; shift 2;; *) exit 2;; esac; done
for value in manifest evidence candidate source_image; do [[ -n "${!value}" ]] || exit 2; done
[[ "$(realpath -- "$manifest")" == "$(realpath -- "$evidence/promotion-acceptance.json")" ]] || { echo 'Promotion manifest must be the canonical file inside its evidence directory.' >&2; exit 1; }
devario_require_closed_tree "$evidence"
python3 "$script_dir/validate-json.py" "$script_dir/promotion-acceptance.schema.json" "$manifest"
jq -e --arg candidate "$(devario_sha256 "$candidate")" --arg candidateVersion "$(jq -r '.version' "$candidate")" --arg edition "$(jq -r '.edition' "$candidate")" '.candidateSha256==$candidate and .candidateVersion==$candidateVersion and .edition==$edition' "$manifest" >/dev/null || { echo 'Acceptance evidence targets another candidate identity.' >&2; exit 1; }
source_relative="$(devario_candidate_artifact_path "$candidate" "$source_image")" || {
  echo 'Acceptance source image is not one unambiguous exact candidate artifact subject.' >&2; exit 1;
}

mapfile -t declared < <(jq -r '["promotion-acceptance.json",.installedDisk.path,.installationLock.path,.installationReview.document.path,.installationReview.signature.path] + [.results[] | .document.path,.log.path] | .[]' "$manifest" | sort)
mapfile -t actual < <(find "$evidence" -maxdepth 1 -type f ! -name ACCEPTANCE.SHA256SUMS -printf '%f\n' | sort)
[[ "$(printf '%s\n' "${declared[@]}")" == "$(printf '%s\n' "${actual[@]}")" ]] || { echo 'Acceptance evidence contains missing, duplicate, or undeclared files.' >&2; exit 1; }
while IFS=$'\t' read -r path sha size; do
  file="$evidence/$path"; [[ -f "$file" && ! -L "$file" ]] || exit 1
  [[ "$(devario_sha256 "$file")" == "$sha" && "$(stat -c '%s' "$file")" == "$size" ]] || { echo "Evidence digest mismatch: $path" >&2; exit 1; }
done < <(jq -r '[.installedDisk,.installationLock,.installationReview.document,.installationReview.signature,.results[].document,.results[].log][] | [.path,.sha256,(.size|tostring)] | @tsv' "$manifest")
temporary="$(mktemp /tmp/devario-acceptance-sums.XXXXXX)"; trap 'rm -f -- "$temporary"' EXIT
(cd "$evidence" && find . -maxdepth 1 -type f ! -name ACCEPTANCE.SHA256SUMS -printf '%f\0' | sort -z | xargs -0 sha256sum -- > "$temporary")
cmp -s "$temporary" "$evidence/ACCEPTANCE.SHA256SUMS" || { echo 'ACCEPTANCE.SHA256SUMS is not canonical or is stale.' >&2; exit 1; }
while IFS= read -r -d '' file; do (( (8#$(stat -c '%a' "$file") & 8#222) == 0 )) || { echo "Final evidence remains writable: ${file#"$evidence/"}" >&2; exit 1; }; done < <(find "$evidence" -type f -print0)

disk="$evidence/$(jq -r '.installedDisk.path' "$manifest")"; lock="$evidence/$(jq -r '.installationLock.path' "$manifest")"; review="$evidence/$(jq -r '.installationReview.document.path' "$manifest")"; signature="$evidence/$(jq -r '.installationReview.signature.path' "$manifest")"
bash "$script_dir/validate-installation-lock.sh" --lock "$lock" --candidate "$candidate" --source-image "$source_image" --disk "$disk"
bash "$script_dir/validate-installation-review.sh" --review "$review" --signature "$signature" --installation-lock "$lock" --candidate "$candidate" --disk "$disk" --trust-policy "$policy" --keyring "$keyring"

while IFS=$'\t' read -r mode firmware document log; do
  result="$evidence/$document"; log_file="$evidence/$log"
  python3 "$script_dir/validate-json.py" "$script_dir/image-acceptance.schema.json" "$result"
  expected="DEVARIO_ACCEPTANCE:PASS mode=$mode firmware=$firmware edition=$(jq -r '.edition' "$candidate")"
  jq -e --arg candidate "$(devario_sha256 "$candidate")" --arg candidateVersion "$(jq -r '.version' "$candidate")" --arg mode "$mode" --arg firmware "$firmware" --arg marker "$expected" \
    --arg logName "$(basename -- "$log_file")" --arg logSha "$(devario_sha256 "$log_file")" --argjson logSize "$(stat -c '%s' "$log_file")" \
    '.candidateSha256==$candidate and .candidateVersion==$candidateVersion and .mode==$mode and .firmware==$firmware and .marker==$marker and .log=={name:$logName,sha256:$logSha,size:$logSize}' "$result" >/dev/null || { echo "Acceptance result binding mismatch: $document" >&2; exit 1; }
  if [[ "$mode" == live ]]; then expected_image="$source_image"; else expected_image="$disk"; fi
  jq -e --arg name "$(basename -- "$expected_image")" --arg sha "$(devario_sha256 "$expected_image")" --argjson size "$(stat -c '%s' "$expected_image")" '.image=={name:$name,sha256:$sha,size:$size}' "$result" >/dev/null || { echo "Acceptance result targets the wrong image: $document" >&2; exit 1; }
  marker_count="$(sed $'s/\r$//; s/\033\[[0-9;]*[[:alpha:]]//g' "$log_file" | grep -Ec '^DEVARIO_ACCEPTANCE:(PASS|FAIL)' || true)"
  exact_count="$(sed $'s/\r$//; s/\033\[[0-9;]*[[:alpha:]]//g' "$log_file" | grep -Fxc "$expected" || true)"
  [[ "$marker_count" == 1 && "$exact_count" == 1 ]] || { echo "Log does not contain exactly one clean expected marker: $log" >&2; exit 1; }
done < <(jq -r '.results[] | [.mode,.firmware,.document.path,.log.path] | @tsv' "$manifest")
echo 'Validated closed live BIOS/UEFI and installed UEFI promotion acceptance evidence.'
