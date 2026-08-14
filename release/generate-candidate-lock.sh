#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-release.sh
source "$script_dir/lib-release.sh"

usage() {
  echo 'Usage: generate-candidate-lock.sh --artifacts DIR --metadata DIR --output FILE --edition community|managed --version VERSION --architecture ARCH --channel CHANNEL --core-commit SHA --core-input-lock FILE --builder-manifest FILE --builder-manifest-signature FILE --builder-attestation FILE --builder-attestation-signature FILE --builder-output-tree DIR [--overlay-commit SHA --overlay-input-lock FILE]' >&2
}

artifacts='' metadata='' output='' edition='' version='' architecture='' channel=''
core_commit='' overlay_commit='' core_input_lock='' overlay_input_lock='' builder_manifest='' builder_manifest_signature='' builder_attestation='' builder_attestation_signature='' builder_output_tree=''
while (( $# )); do
  case "$1" in
    --artifacts) artifacts="$2"; shift 2 ;;
    --metadata) metadata="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --edition) edition="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --architecture) architecture="$2"; shift 2 ;;
    --channel) channel="$2"; shift 2 ;;
    --core-commit) core_commit="$2"; shift 2 ;;
    --overlay-commit) overlay_commit="$2"; shift 2 ;;
    --core-input-lock) core_input_lock="$2"; shift 2 ;;
    --overlay-input-lock) overlay_input_lock="$2"; shift 2 ;;
    --builder-manifest) builder_manifest="$2"; shift 2 ;;
    --builder-manifest-signature) builder_manifest_signature="$2"; shift 2 ;;
    --builder-attestation) builder_attestation="$2"; shift 2 ;;
    --builder-attestation-signature) builder_attestation_signature="$2"; shift 2 ;;
    --builder-output-tree) builder_output_tree="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
for value in artifacts metadata output edition version architecture channel core_commit core_input_lock builder_manifest builder_manifest_signature builder_attestation builder_attestation_signature builder_output_tree; do
  [[ -n "${!value}" ]] || { echo "Missing --${value//_/-}." >&2; usage; exit 2; }
done
[[ "$core_commit" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid core commit.' >&2; exit 1; }
devario_validate_release_version "$version" || { echo 'Invalid canonical release version.' >&2; exit 1; }
if [[ "$edition" == managed ]]; then
  [[ "$overlay_commit" =~ ^[0-9a-f]{40}$ && -f "$overlay_input_lock" ]] || {
    echo 'Managed candidates require an overlay commit and overlay input lock.' >&2; exit 1;
  }
elif [[ "$edition" == community ]]; then
  [[ -z "$overlay_commit" && -z "$overlay_input_lock" ]] || {
    echo 'Community candidates cannot bind a managed overlay.' >&2; exit 1;
  }
else
  echo 'Edition must be community or managed.' >&2; exit 1
fi
if [[ "$edition:$channel" != community:devario-core-testing && "$edition:$channel" != managed:devario-managed-pilot ]]; then
  echo 'Candidate channel is not the allowed channel for this edition.' >&2; exit 1
fi
[[ "${SOURCE_DATE_EPOCH:-}" =~ ^[1-9][0-9]*$ ]] || {
  echo 'SOURCE_DATE_EPOCH must be a positive integer.' >&2; exit 1;
}
for evidence in "$core_input_lock" "$builder_manifest" "$builder_attestation"; do
  [[ -f "$evidence" && ! -L "$evidence" ]] || { echo "Missing regular evidence file: $evidence" >&2; exit 1; }
  jq -e 'type == "object"' "$evidence" >/dev/null || { echo "Evidence is not a JSON object: $evidence" >&2; exit 1; }
done
for signature in "$builder_manifest_signature" "$builder_attestation_signature"; do [[ -f "$signature" && ! -L "$signature" && -s "$signature" ]] || { echo "Missing build-evidence signature: $signature" >&2; exit 1; }; done
if [[ -n "$overlay_input_lock" ]]; then
  jq -e 'type == "object"' "$overlay_input_lock" >/dev/null || { echo 'Overlay input lock is not JSON.' >&2; exit 1; }
fi
build_evidence_args=(--input-lock "$core_input_lock" --builder-manifest "$builder_manifest" --builder-manifest-signature "$builder_manifest_signature" --attestation "$builder_attestation" --attestation-signature "$builder_attestation_signature" --output-tree "$builder_output_tree" --edition "$edition" --release-version "$version" --architecture "$architecture" --core-commit "$core_commit" --source-date-epoch "$SOURCE_DATE_EPOCH" --allow-pending)
if [[ -n "$overlay_commit" ]]; then build_evidence_args+=(--overlay-commit "$overlay_commit" --managed-input-lock "$overlay_input_lock"); fi
bash "$script_dir/validate-build-evidence.sh" "${build_evidence_args[@]}"
[[ ! -e "$output" ]] || { echo "Candidate lock already exists: $output" >&2; exit 1; }

temp_dir="$(mktemp -d /tmp/devario-candidate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT
devario_tree_json "$(realpath -- "$artifacts")" "$temp_dir/artifacts.json"
devario_tree_json "$(realpath -- "$metadata")" "$temp_dir/metadata.json"
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
artifact_digest="$(devario_tree_set_digest "$temp_dir/artifacts.json")"
metadata_digest="$(devario_tree_set_digest "$temp_dir/metadata.json")"

(cd "$artifacts" && sha256sum -c "$metadata/SHA256SUMS")
(cd "$metadata" && sha256sum -c METADATA.SHA256SUMS)
python3 "$script_dir/validate-json.py" "$script_dir/release-metadata.schema.json" "$metadata/release.json"
jq -e --slurpfile tree "$temp_dir/artifacts.json" '
  .subjects == [$tree[0][] | select(.mode != "120000") | {name:.path,digest:{sha256:.sha256},size:.size}]
' "$metadata/release.json" >/dev/null || { echo 'release.json subjects do not exactly equal the regular-file artifact closure.' >&2; exit 1; }
jq -e --arg inventory "$(devario_sha256 "$metadata/IMAGE-PACKAGE-INVENTORY.json")" --arg sources "$(devario_sha256 "$metadata/source-index.json")" '
  .imagePackageInventory=={path:"IMAGE-PACKAGE-INVENTORY.json",sha256:$inventory} and
  .correspondingSourceIndex=={path:"source-index.json",sha256:$sources}
' "$metadata/release.json" >/dev/null || { echo 'Release metadata does not bind its installed inventory/source index.' >&2; exit 1; }
python3 "$script_dir/validate-json.py" "$script_dir/installed-package-inventory.schema.json" "$metadata/IMAGE-PACKAGE-INVENTORY.json"
python3 "$script_dir/validate-json.py" "$script_dir/source-index.schema.json" "$metadata/source-index.json"
devario_validate_source_binary_closure "$metadata/source-index.json" "$artifacts"
devario_validate_inventory_source_spdx "$metadata"
jq -e --arg edition "$edition" --arg version "$version" --arg architecture "$architecture" \
  --arg channel "$channel" --arg core "$core_commit" --arg overlay "${overlay_commit:-}" \
  --argjson epoch "$SOURCE_DATE_EPOCH" '
    .edition == $edition and .version == $version and .architecture == $architecture and
    .channel == $channel and .source.coreCommit == $core and .sourceDateEpoch == $epoch and
    (if $overlay == "" then .source.overlayCommit == null else .source.overlayCommit == $overlay end)
  ' "$metadata/release.json" >/dev/null || { echo 'Release metadata does not describe this candidate.' >&2; exit 1; }

created_at="$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"
overlay_json='null'; overlay_evidence='null'
if [[ -n "$overlay_commit" ]]; then
  overlay_json="$(jq -cn --arg value "$overlay_commit" '$value')"
  overlay_evidence="$(jq -cn --arg name "$(basename -- "$overlay_input_lock")" --arg sha256 "$(devario_sha256 "$overlay_input_lock")" '{name:$name,sha256:$sha256}')"
fi
mkdir -p -- "$(dirname -- "$output")"
jq -n \
  --arg edition "$edition" --arg version "$version" --arg architecture "$architecture" \
  --arg channel "$channel" --arg core "$core_commit" --argjson overlay "$overlay_json" \
  --argjson epoch "$SOURCE_DATE_EPOCH" --arg created "$created_at" \
  --slurpfile artifacts "$temp_dir/artifacts.json" --arg artifactSet "$artifact_digest" \
  --slurpfile metadata "$temp_dir/metadata.json" --arg metadataSet "$metadata_digest" \
  --arg coreLockName "$(basename -- "$core_input_lock")" --arg coreLockSha "$(devario_sha256 "$core_input_lock")" \
  --arg manifestName "$(basename -- "$builder_manifest")" --arg manifestSha "$(devario_sha256 "$builder_manifest")" \
  --arg manifestSignatureName "$(basename -- "$builder_manifest_signature")" --arg manifestSignatureSha "$(devario_sha256 "$builder_manifest_signature")" \
  --arg builderName "$(basename -- "$builder_attestation")" --arg builderSha "$(devario_sha256 "$builder_attestation")" \
  --arg builderSignatureName "$(basename -- "$builder_attestation_signature")" --arg builderSignatureSha "$(devario_sha256 "$builder_attestation_signature")" \
  --argjson overlayEvidence "$overlay_evidence" '
  {
    schemaVersion: 2, edition: $edition, version: $version, architecture: $architecture,
    candidateChannel: $channel, coreCommit: $core, overlayCommit: $overlay,
    sourceDateEpoch: $epoch, createdAt: $created,
    artifacts: $artifacts[0], artifactSetSha256: $artifactSet,
    metadata: $metadata[0], metadataSetSha256: $metadataSet,
    buildEvidence: {
      coreInputLock: {name:$coreLockName,sha256:$coreLockSha},
      overlayInputLock: $overlayEvidence,
      builderManifest: {name:$manifestName,sha256:$manifestSha},
      builderManifestSignature: {name:$manifestSignatureName,sha256:$manifestSignatureSha},
      builderAttestation: {name:$builderName,sha256:$builderSha},
      builderAttestationSignature: {name:$builderSignatureName,sha256:$builderSignatureSha}
    }
  }' > "$temp_dir/candidate-lock.json"
python3 "$script_dir/validate-json.py" "$script_dir/candidate-lock.schema.json" "$temp_dir/candidate-lock.json"
install -m 0444 "$temp_dir/candidate-lock.json" "$output"
echo "Finalized candidate lock: $output"
