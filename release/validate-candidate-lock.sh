#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
source "$script_dir/lib-release.sh"
candidate='' artifacts='' metadata='' core_input_lock='' overlay_input_lock='' builder_manifest='' builder_manifest_signature='' builder_attestation='' builder_attestation_signature='' builder_output_tree=''
core_source='' overlay_source='' core_keyring='' managed_keyring='' core_repository='' managed_repository='' source_image='' core_url='' managed_url='' allow_pending=0
bootstrap_archive='' bootstrap_signature='' arch_snapshot_dir='' arch_keyring='' shelly_bootstrap='' shelly_bootstrap_signature='' dependency_closure=''
while (( $# )); do
  case "$1" in
    --candidate) candidate="$2"; shift 2 ;;
    --artifacts) artifacts="$2"; shift 2 ;;
    --metadata) metadata="$2"; shift 2 ;;
    --core-input-lock) core_input_lock="$2"; shift 2 ;;
    --overlay-input-lock) overlay_input_lock="$2"; shift 2 ;;
    --builder-attestation) builder_attestation="$2"; shift 2 ;;
    --builder-attestation-signature) builder_attestation_signature="$2"; shift 2 ;;
    --builder-manifest) builder_manifest="$2"; shift 2 ;;
    --builder-manifest-signature) builder_manifest_signature="$2"; shift 2 ;;
    --builder-output-tree) builder_output_tree="$2"; shift 2 ;;
    --core-source) core_source="$2"; shift 2 ;;
    --overlay-source) overlay_source="$2"; shift 2 ;;
    --core-keyring) core_keyring="$2"; shift 2 ;;
    --managed-keyring) managed_keyring="$2"; shift 2 ;;
    --core-repository) core_repository="$2"; shift 2 ;;
    --managed-repository) managed_repository="$2"; shift 2 ;;
    --source-image) source_image="$2"; shift 2 ;;
    --core-url) core_url="$2"; shift 2 ;;
    --managed-url) managed_url="$2"; shift 2 ;;
    --bootstrap-archive) bootstrap_archive="$2"; shift 2 ;;
    --bootstrap-signature) bootstrap_signature="$2"; shift 2 ;;
    --arch-snapshot-dir) arch_snapshot_dir="$2"; shift 2 ;;
    --arch-keyring) arch_keyring="$2"; shift 2 ;;
    --shelly-bootstrap) shelly_bootstrap="$2"; shift 2 ;;
    --shelly-bootstrap-signature) shelly_bootstrap_signature="$2"; shift 2 ;;
    --dependency-closure) dependency_closure="$2"; shift 2 ;;
    --allow-pending) allow_pending=1; shift ;;
    *) echo 'Usage: validate-candidate-lock.sh --candidate FILE --artifacts DIR --metadata DIR --core-input-lock FILE --builder-manifest FILE --builder-manifest-signature FILE --builder-attestation FILE --builder-attestation-signature FILE --builder-output-tree DIR [--overlay-input-lock FILE] [production: --core-source DIR --core-keyring DIR --core-repository DIR --core-url HTTPS_URL --source-image ISO plus immutable bootstrap/snapshot/dependency inputs] [--allow-pending]' >&2; exit 2 ;;
  esac
done
for value in candidate artifacts metadata core_input_lock builder_manifest builder_manifest_signature builder_attestation builder_attestation_signature builder_output_tree; do
  [[ -n "${!value}" ]] || { echo "Missing $value." >&2; exit 2; }
done
python3 "$script_dir/validate-json.py" "$script_dir/candidate-lock.schema.json" "$candidate"
temp_dir="$(mktemp -d /tmp/devario-candidate-validate.XXXXXX)"; trap 'rm -rf -- "$temp_dir"' EXIT
devario_tree_json "$(realpath -- "$artifacts")" "$temp_dir/artifacts.json"
devario_tree_json "$(realpath -- "$metadata")" "$temp_dir/metadata.json"
jq -S -e --slurpfile actual "$temp_dir/artifacts.json" '.artifacts == $actual[0]' "$candidate" >/dev/null || { echo 'Artifact tree differs from the candidate lock.' >&2; exit 1; }
jq -S -e --slurpfile actual "$temp_dir/metadata.json" '.metadata == $actual[0]' "$candidate" >/dev/null || { echo 'Metadata tree differs from the candidate lock.' >&2; exit 1; }
[[ "$(devario_tree_set_digest "$temp_dir/artifacts.json")" == "$(jq -r '.artifactSetSha256' "$candidate")" ]] || { echo 'Artifact set digest mismatch.' >&2; exit 1; }
[[ "$(devario_tree_set_digest "$temp_dir/metadata.json")" == "$(jq -r '.metadataSetSha256' "$candidate")" ]] || { echo 'Metadata set digest mismatch.' >&2; exit 1; }
if ! jq -e --slurpfile artifacts "$temp_dir/artifacts.json" '
  .outputs as $outputs |
  all($artifacts[0][];
    . as $artifact | any($outputs[];
      .path==$artifact.path and
      (if $artifact.mode == "120000" then
        .mode == "120000" and .target == $artifact.target
      else
        .sha256 == $artifact.sha256 and .size == $artifact.size
      end)
    )
  )
' "$builder_attestation" >/dev/null; then
  echo 'Candidate artifact tree is not an exact publishable subset of the attested builder outputs.' >&2
  exit 1
fi
for binding in "coreInputLock:$core_input_lock" "builderManifest:$builder_manifest" "builderManifestSignature:$builder_manifest_signature" "builderAttestation:$builder_attestation" "builderAttestationSignature:$builder_attestation_signature"; do
  key="${binding%%:*}"; file="${binding#*:}"
  [[ -f "$file" && ! -L "$file" ]] || { echo "Missing evidence file: $file" >&2; exit 1; }
  jq -e --arg key "$key" --arg name "$(basename -- "$file")" --arg sha "$(devario_sha256 "$file")" \
    '.buildEvidence[$key] == {name:$name,sha256:$sha}' "$candidate" >/dev/null || { echo "$key binding mismatch." >&2; exit 1; }
done
edition="$(jq -r '.edition' "$candidate")"
candidate_channel="$(jq -r '.candidateChannel' "$candidate")"
if [[ "$edition:$candidate_channel" != community:devario-core-testing && "$edition:$candidate_channel" != managed:devario-managed-pilot ]]; then
  echo 'Candidate uses a forbidden edition/channel pairing.' >&2; exit 1
fi
if [[ "$edition" == managed ]]; then
  [[ -f "$overlay_input_lock" ]] || { echo 'Managed candidate overlay input lock is missing.' >&2; exit 1; }
  jq -e --arg name "$(basename -- "$overlay_input_lock")" --arg sha "$(devario_sha256 "$overlay_input_lock")" \
    '.buildEvidence.overlayInputLock == {name:$name,sha256:$sha}' "$candidate" >/dev/null || { echo 'Overlay input-lock binding mismatch.' >&2; exit 1; }
elif [[ -n "$overlay_input_lock" ]]; then
  echo 'Community candidate cannot accept an overlay input lock.' >&2; exit 1
fi
build_evidence_args=(--input-lock "$core_input_lock" --builder-manifest "$builder_manifest" --builder-manifest-signature "$builder_manifest_signature" --attestation "$builder_attestation" --attestation-signature "$builder_attestation_signature" --output-tree "$builder_output_tree" --edition "$edition" --release-version "$(jq -r '.version' "$candidate")" --architecture "$(jq -r '.architecture' "$candidate")" --core-commit "$(jq -r '.coreCommit' "$candidate")" --source-date-epoch "$(jq -r '.sourceDateEpoch' "$candidate")")
if [[ "$edition" == managed ]]; then build_evidence_args+=(--overlay-commit "$(jq -r '.overlayCommit' "$candidate")" --managed-input-lock "$overlay_input_lock"); fi
if (( allow_pending )); then build_evidence_args+=(--allow-pending)
else
  # ISO construction and its controlled-builder manifest remain core-owned for
  # both editions. Managed package/input evidence is verified separately under
  # the distinct Managed signer below.
  build_evidence_args+=(--keyring-dir "$core_keyring" --repository-name devario-core)
fi
bash "$script_dir/validate-build-evidence.sh" "${build_evidence_args[@]}"
(cd "$artifacts" && sha256sum -c "$metadata/SHA256SUMS")
(cd "$metadata" && sha256sum -c METADATA.SHA256SUMS)
python3 "$script_dir/validate-json.py" "$script_dir/release-metadata.schema.json" "$metadata/release.json"
jq -e --slurpfile tree "$temp_dir/artifacts.json" '.subjects == [$tree[0][] | select(.mode != "120000") | {name:.path,digest:{sha256:.sha256},size:.size}]' "$metadata/release.json" >/dev/null || { echo 'Release subjects do not exactly equal regular-file candidate artifacts.' >&2; exit 1; }
for file in IMAGE-PACKAGE-INVENTORY.json source-index.json installed-packages.spdx.json; do [[ -f "$metadata/$file" && ! -L "$metadata/$file" ]] || { echo "Metadata omits $file." >&2; exit 1; }; done
python3 "$script_dir/validate-json.py" "$script_dir/installed-package-inventory.schema.json" "$metadata/IMAGE-PACKAGE-INVENTORY.json"
python3 "$script_dir/validate-json.py" "$script_dir/source-index.schema.json" "$metadata/source-index.json"
devario_validate_source_binary_closure "$metadata/source-index.json" "$artifacts"
jq -e --arg inventory "$(devario_sha256 "$metadata/IMAGE-PACKAGE-INVENTORY.json")" --arg sources "$(devario_sha256 "$metadata/source-index.json")" '.imagePackageInventory=={path:"IMAGE-PACKAGE-INVENTORY.json",sha256:$inventory} and .correspondingSourceIndex=={path:"source-index.json",sha256:$sources}' "$metadata/release.json" >/dev/null || { echo 'Release inventory/source bindings are stale.' >&2; exit 1; }
devario_validate_inventory_source_spdx "$metadata"

check_source() {
  local source="$1" expected="$2" label="$3" dirty ignored
  [[ -d "$source/.git" ]] || { echo "$label source is not a Git checkout." >&2; return 1; }
  [[ "$(git -C "$source" rev-parse HEAD)" == "$expected" ]] || { echo "$label HEAD differs from the candidate." >&2; return 1; }
  dirty="$(git -C "$source" status --porcelain=v1 --untracked-files=all)"
  [[ -z "$dirty" ]] || { echo "$label source is dirty." >&2; return 1; }
  ignored="$(git -C "$source" ls-files --others --ignored --exclude-standard)"
  [[ -z "$ignored" ]] || { echo "$label source contains ignored material." >&2; return 1; }
  if git -C "$source" ls-files -v | awk 'substr($1,1,1) == "S" || substr($1,1,1) ~ /[a-z]/ {found=1} END {exit !found}'; then
    echo "$label source uses skip-worktree or assume-unchanged index flags." >&2; return 1
  fi
  git -C "$source" diff-index --quiet HEAD -- || { echo "$label source index or file modes differ from HEAD." >&2; return 1; }
}
if [[ -n "$core_source" ]]; then check_source "$core_source" "$(jq -r '.coreCommit' "$candidate")" Core; fi
if [[ "$edition" == managed && -n "$overlay_source" ]]; then check_source "$overlay_source" "$(jq -r '.overlayCommit' "$candidate")" Managed; fi
if (( allow_pending )); then
  echo 'Validated exact pending candidate trees and build-evidence bindings.'
  exit 0
fi
[[ -n "$core_source" && -n "$core_keyring" && -n "$core_repository" && -n "$source_image" && -n "$core_url" ]] || { echo 'Production validation requires clean core source, core repository/trust/URL, and the exact source image.' >&2; exit 1; }
for value in bootstrap_archive bootstrap_signature arch_snapshot_dir arch_keyring shelly_bootstrap shelly_bootstrap_signature dependency_closure; do [[ -n "${!value}" ]] || { echo "Production input-lock verification is missing $value." >&2; exit 2; }; done
case "$(realpath -- "$core_repository")/" in "$(realpath -- "$artifacts")/"*) ;; *) echo 'Core repository must be inside the locked artifact tree.' >&2; exit 1;; esac
if [[ "$edition" == managed ]]; then
  [[ -n "$overlay_source" && -n "$managed_keyring" && -n "$managed_repository" && -n "$managed_url" ]] || { echo 'Managed production validation requires overlay source, managed repository/trust, and managed URL.' >&2; exit 1; }
  case "$(realpath -- "$managed_repository")/" in "$(realpath -- "$artifacts")/"*) ;; *) echo 'Managed repository must be inside the locked artifact tree.' >&2; exit 1;; esac
else
  [[ -z "$managed_keyring" && -z "$managed_repository" && -z "$overlay_source" && -z "$managed_url" ]] || { echo 'Community production validation rejects managed trust, repository, source, and URL inputs.' >&2; exit 1; }
fi
edition_source="$core_source/editions/community"; builder_keyring="$core_keyring"; builder_repository=devario-core
input_verify_args=(--operation iso --core "$core_source" --edition "$edition_source" --bootstrap-archive "$bootstrap_archive" --bootstrap-signature "$bootstrap_signature" --bootstrap-url "$(jq -r '.bootstrap.url' "$core_input_lock")" --arch-snapshot-dir "$arch_snapshot_dir" --arch-snapshot-url "$(jq -r '.archSnapshot.url' "$core_input_lock")" --arch-keyring "$arch_keyring" --shelly-bootstrap "$shelly_bootstrap" --shelly-bootstrap-signature "$shelly_bootstrap_signature" --builder-manifest "$builder_manifest" --builder-manifest-signature "$builder_manifest_signature" --builder-keyring "$builder_keyring" --builder-repository "$builder_repository" --dependency-closure "$dependency_closure" --source-date-epoch "$(jq -r '.sourceDateEpoch' "$candidate")" --release-version "$(jq -r '.version' "$candidate")" --core-repo "$core_repository" --core-keyring "$core_keyring" --verify "$core_input_lock")
if [[ "$edition" == managed ]]; then
  edition_source="$overlay_source"
  input_verify_args=(--operation iso --core "$core_source" --edition "$edition_source" --bootstrap-archive "$bootstrap_archive" --bootstrap-signature "$bootstrap_signature" --bootstrap-url "$(jq -r '.bootstrap.url' "$core_input_lock")" --arch-snapshot-dir "$arch_snapshot_dir" --arch-snapshot-url "$(jq -r '.archSnapshot.url' "$core_input_lock")" --arch-keyring "$arch_keyring" --shelly-bootstrap "$shelly_bootstrap" --shelly-bootstrap-signature "$shelly_bootstrap_signature" --builder-manifest "$builder_manifest" --builder-manifest-signature "$builder_manifest_signature" --builder-keyring "$builder_keyring" --builder-repository "$builder_repository" --dependency-closure "$dependency_closure" --source-date-epoch "$(jq -r '.sourceDateEpoch' "$candidate")" --release-version "$(jq -r '.version' "$candidate")" --core-repo "$core_repository" --core-keyring "$core_keyring" --managed-repo "$managed_repository" --managed-keyring "$managed_keyring" --managed-input-lock "$overlay_input_lock" --verify "$core_input_lock")
fi
bash "$project_dir/scripts/verify-core-input-lock.sh" "${input_verify_args[@]}"
devario_candidate_artifact_path "$candidate" "$source_image" >/dev/null || { echo 'Production source image is not one unambiguous exact candidate artifact.' >&2; exit 1; }
image_args=(--iso "$source_image" --edition "$edition" --release --input-lock "$core_input_lock" --release-version "$(jq -r '.version' "$candidate")" --core-keyring "$core_keyring" --core-url "$core_url" --expected-inventory "$metadata/IMAGE-PACKAGE-INVENTORY.json")
if [[ "$edition" == managed ]]; then
  [[ -n "$managed_keyring" && -n "$managed_url" ]] || { echo 'Managed image validation requires managed trust and URL.' >&2; exit 1; }
  image_args+=(--managed-keyring "$managed_keyring" --managed-url "$managed_url")
elif [[ -n "$managed_url" ]]; then echo 'Community validation rejects a managed URL.' >&2; exit 1
fi
bash "$project_dir/scripts/verify-image-boundary.sh" "${image_args[@]}"
bash "$script_dir/verify-repository-signatures.sh" --artifacts "$core_repository" --keyring-dir "$core_keyring" --repository-name devario-core
if [[ "$edition" == managed ]]; then
  # The ISO CORE lock binds the canonical MANAGED-INPUT-LOCK used to compose
  # this image. It is deliberately not passed to the overlay package-lock
  # validator: that validator requires the distinct external-packages CORE
  # lock retained in the managed package-build output. The managed v3 release
  # lock/bridge validates that later evidence layer without conflating it with
  # this candidate's ISO build closure.
  bash "$script_dir/verify-repository-signatures.sh" --artifacts "$managed_repository" --keyring-dir "$managed_keyring" --repository-name devario-managed
else
  if find "$artifacts" -print | grep -Eqi 'devario-managed|managed-overlay'; then echo 'Community artifact tree contains managed-named material.' >&2; exit 1; fi
fi
echo 'Validated production candidate lock, source, trust, signatures, and exact trees.'
