#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; project_dir="$(cd -- "$script_dir/.." && pwd)"
input_lock='' managed_input_lock='' manifest='' manifest_signature='' attestation='' attestation_signature='' output_tree=''
edition='' release_version='' architecture='' core_commit='' overlay_commit='' source_date_epoch='' keyring_dir='' repository_name='' allow_pending=0
while (( $# )); do case "$1" in
  --input-lock) input_lock="$2"; shift 2;; --managed-input-lock) managed_input_lock="$2"; shift 2;; --builder-manifest) manifest="$2"; shift 2;; --builder-manifest-signature) manifest_signature="$2"; shift 2;;
  --attestation) attestation="$2"; shift 2;; --attestation-signature) attestation_signature="$2"; shift 2;; --output-tree) output_tree="$2"; shift 2;;
  --edition) edition="$2"; shift 2;; --release-version) release_version="$2"; shift 2;; --architecture) architecture="$2"; shift 2;; --core-commit) core_commit="$2"; shift 2;; --overlay-commit) overlay_commit="$2"; shift 2;; --source-date-epoch) source_date_epoch="$2"; shift 2;;
  --keyring-dir) keyring_dir="$2"; shift 2;; --repository-name) repository_name="$2"; shift 2;; --allow-pending) allow_pending=1; shift;; *) exit 2;; esac; done
for value in input_lock manifest manifest_signature attestation attestation_signature output_tree edition release_version architecture core_commit source_date_epoch; do [[ -n "${!value}" ]] || { echo "Build evidence missing $value." >&2; exit 2; }; done
for file in "$input_lock" "$manifest" "$manifest_signature" "$attestation" "$attestation_signature"; do [[ -f "$file" && ! -L "$file" ]] || { echo "Unsafe build evidence: $file" >&2; exit 1; }; done
[[ -d "$output_tree" && ! -L "$output_tree" ]] || { echo 'Builder output tree must be a real directory.' >&2; exit 1; }
output_tree="$(realpath -e -- "$output_tree")"
canonical_evidence=("$input_lock" "$manifest" "$manifest_signature" "$attestation" "$attestation_signature")
canonical_names=(CORE-INPUT-LOCK.json CONTROLLED-BUILDER.json CONTROLLED-BUILDER.json.sig BUILDER-ATTESTATION.json BUILDER-ATTESTATION.json.sig)
for index in "${!canonical_evidence[@]}"; do
  [[ "$(realpath -e -- "${canonical_evidence[$index]}")" == "$output_tree/${canonical_names[$index]}" ]] || {
    echo "Build evidence must use canonical output-tree path: ${canonical_names[$index]}" >&2
    exit 1
  }
done
python3 "$script_dir/validate-json.py" "$project_dir/scripts/schemas/core-input-lock.schema.json" "$input_lock"
python3 "$script_dir/validate-json.py" "$project_dir/scripts/schemas/controlled-builder.schema.json" "$manifest"
python3 "$script_dir/validate-json.py" "$project_dir/scripts/schemas/builder-attestation.schema.json" "$attestation"
python3 - "$input_lock" "$manifest" "$attestation" <<'PY'
import json,pathlib,sys
def hook(pairs):
 out={}
 for key,value in pairs:
  if key in out: raise SystemExit(f"duplicate JSON key: {key}")
  out[key]=value
 return out
for value in sys.argv[1:]:
 path=pathlib.Path(value); document=json.loads(path.read_bytes(),object_pairs_hook=hook)
 canonical=(json.dumps(document,sort_keys=True,separators=(",",":"))+"\n").encode()
 if path.read_bytes()!=canonical: raise SystemExit(f"build evidence is not canonical JSON: {path}")
PY
sha() { sha256sum "$1" | cut -d' ' -f1; }
expected_edition_commit="$core_commit"; [[ "$edition" == managed ]] && expected_edition_commit="$overlay_commit"
jq -e --arg core "$core_commit" --arg edition "$edition" --arg editionCommit "$expected_edition_commit" \
  --arg version "$release_version" --arg architecture "$architecture" --argjson epoch "$source_date_epoch" \
  '.operation=="iso" and .releaseVersion==$version and .architecture==$architecture and .core.commit==$core and .edition.id==$edition and .edition.commit==$editionCommit and .sourceDateEpoch==$epoch' "$input_lock" >/dev/null || { echo 'Input lock version/source/edition/architecture/SDE identity differs from the release.' >&2; exit 1; }
jq -e --arg core "$core_commit" --arg edition "$edition" --arg version "$release_version" --argjson epoch "$source_date_epoch" \
  '.operation=="iso" and .releaseVersion==$version and .coreCommit==$core and .edition==$edition and .sourceDateEpoch==$epoch' "$attestation" >/dev/null || { echo 'Signed attestation version/source/edition/SDE identity differs from the release.' >&2; exit 1; }
if [[ "$edition" == managed ]]; then
  [[ -f "$managed_input_lock" && ! -L "$managed_input_lock" ]] || { echo 'Managed build evidence requires MANAGED-INPUT-LOCK.json.' >&2; exit 1; }
  managed_sha="$(sha "$managed_input_lock")"
  jq -e --arg managed "$managed_sha" '.managedInputLockSha256==$managed' "$input_lock" >/dev/null || { echo 'Core input lock does not bind managed input lock.' >&2; exit 1; }
  jq -e --arg managed "$managed_sha" '.managedInputLockSha256==$managed and .edition=="managed"' "$attestation" >/dev/null || { echo 'Signed attestation does not bind managed input lock/edition.' >&2; exit 1; }
  [[ "$(realpath -- "$managed_input_lock")" == "$(realpath -- "$output_tree/MANAGED-INPUT-LOCK.json")" ]] || { echo 'Managed input lock must be the canonical attested output-tree file.' >&2; exit 1; }
else
  [[ -z "$managed_input_lock" ]] || { echo 'Community build evidence rejects a managed input lock.' >&2; exit 1; }
fi
jq -e --arg manifest "$(sha "$manifest")" --arg signature "$(sha "$manifest_signature")" --slurpfile builder "$manifest" '
  .controlledBuilder.manifestSha256==$manifest and .controlledBuilder.manifestSignatureSha256==$signature and
  .controlledBuilder.rootTreeSha256==$builder[0].rootTreeSha256 and
  .controlledBuilder.dependencyClosureSha256==$builder[0].dependencyClosureSha256 and
  .repositorySnapshot==$builder[0].repositorySnapshot and .bootstrap==$builder[0].bootstrap and .shellyBootstrap==$builder[0].shellyBootstrap
' "$input_lock" >/dev/null || { echo 'Controlled-builder manifest does not match the input lock.' >&2; exit 1; }
python3 "$project_dir/scripts/verify-builder-attestation.py" --attestation "$attestation" --input-lock "$input_lock" --output-tree "$output_tree"
if (( allow_pending )); then echo 'Validated canonical build evidence semantics and exact attested output closure.'; exit 0; fi
[[ -n "$keyring_dir" && -n "$repository_name" ]] || { echo 'Production build evidence validation requires its fixed signing keyring.' >&2; exit 1; }
bash "$project_dir/scripts/verify-builder-attestation.sh" \
  --attestation "$attestation" --signature "$attestation_signature" \
  --input-lock "$input_lock" --output-tree "$output_tree" \
  --keyring-dir "$keyring_dir" --repository-name "$repository_name"
echo 'Validated controlled-builder and output attestation under the exact active signer.'
