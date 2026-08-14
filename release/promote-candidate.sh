#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; source "$script_dir/lib-release.sh"
candidate='' artifacts='' metadata='' core_input_lock='' overlay_input_lock='' builder_manifest='' builder_manifest_signature='' builder_attestation='' builder_attestation_signature='' builder_output_tree=''
reproducibility='' acceptance='' edition_evidence='' source_image='' approval='' approval_signature='' destination=''
core_source='' overlay_source='' core_keyring='' managed_keyring='' core_repository='' managed_repository=''
target_channel=''
core_url='' managed_url=''
bootstrap_archive='' bootstrap_signature='' arch_snapshot_dir='' arch_keyring='' shelly_bootstrap='' shelly_bootstrap_signature='' dependency_closure=''
while (( $# )); do
  case "$1" in
    --candidate) candidate="$2"; shift 2;; --artifacts) artifacts="$2"; shift 2;; --metadata) metadata="$2"; shift 2;;
    --core-input-lock) core_input_lock="$2"; shift 2;; --overlay-input-lock) overlay_input_lock="$2"; shift 2;; --builder-attestation) builder_attestation="$2"; shift 2;;
    --builder-manifest) builder_manifest="$2"; shift 2;; --builder-manifest-signature) builder_manifest_signature="$2"; shift 2;; --builder-attestation-signature) builder_attestation_signature="$2"; shift 2;; --builder-output-tree) builder_output_tree="$2"; shift 2;;
    --reproducibility) reproducibility="$2"; shift 2;; --acceptance-manifest) acceptance="$2"; shift 2;; --edition-evidence) edition_evidence="$2"; shift 2;; --source-image) source_image="$2"; shift 2;;
    --approval) approval="$2"; shift 2;; --approval-signature) approval_signature="$2"; shift 2;; --destination) destination="$2"; shift 2;;
    --target-channel) target_channel="$2"; shift 2;;
    --core-source) core_source="$2"; shift 2;; --overlay-source) overlay_source="$2"; shift 2;; --core-keyring) core_keyring="$2"; shift 2;; --managed-keyring) managed_keyring="$2"; shift 2;;
    --core-repository) core_repository="$2"; shift 2;; --managed-repository) managed_repository="$2"; shift 2;;
    --core-url) core_url="$2"; shift 2;; --managed-url) managed_url="$2"; shift 2;;
    --bootstrap-archive) bootstrap_archive="$2"; shift 2;; --bootstrap-signature) bootstrap_signature="$2"; shift 2;; --arch-snapshot-dir) arch_snapshot_dir="$2"; shift 2;; --arch-keyring) arch_keyring="$2"; shift 2;; --shelly-bootstrap) shelly_bootstrap="$2"; shift 2;; --shelly-bootstrap-signature) shelly_bootstrap_signature="$2"; shift 2;; --dependency-closure) dependency_closure="$2"; shift 2;;
    *) echo 'Usage: promote-candidate.sh --candidate FILE --artifacts DIR --metadata DIR --core-input-lock FILE --builder-manifest FILE --builder-manifest-signature FILE --builder-attestation FILE --builder-attestation-signature FILE --builder-output-tree DIR --reproducibility FILE --acceptance-manifest FILE --source-image ISO --approval FILE --approval-signature FILE --target-channel CHANNEL --destination DIR --core-source DIR --core-keyring DIR --core-repository DIR [managed: --overlay-input-lock FILE --overlay-source DIR --managed-keyring DIR --managed-repository DIR --edition-evidence managed-lock.json]' >&2; exit 2;;
  esac
done
for value in candidate artifacts metadata core_input_lock builder_manifest builder_manifest_signature builder_attestation builder_attestation_signature builder_output_tree reproducibility acceptance source_image approval approval_signature target_channel destination core_source core_keyring core_repository core_url bootstrap_archive bootstrap_signature arch_snapshot_dir arch_keyring shelly_bootstrap shelly_bootstrap_signature dependency_closure; do [[ -n "${!value}" ]] || { echo "Missing $value." >&2; exit 2; }; done
[[ ! -e "$destination" ]] || { echo 'Promotion destination already exists; immutable paths cannot be replaced.' >&2; exit 1; }
edition="$(jq -er '.edition' "$candidate")" || { echo 'Cannot read candidate edition.' >&2; exit 1; }
edition_evidence_json='null'
if [[ "$edition" == managed ]]; then
  [[ -n "$edition_evidence" && -f "$edition_evidence" && ! -L "$edition_evidence" && -s "$edition_evidence" ]] || { echo 'Managed promotion requires a regular nonempty --edition-evidence file.' >&2; exit 1; }
  edition_evidence_name="$(basename -- "$edition_evidence")"
  [[ "$edition_evidence_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Managed edition-evidence basename is unsafe.' >&2; exit 1; }
  edition_evidence_json="$(jq -cn --arg name "$edition_evidence_name" --arg sha256 "$(devario_sha256 "$edition_evidence")" '{name:$name,sha256:$sha256}')"
elif [[ -n "$edition_evidence" ]]; then
  echo 'Community promotion rejects edition-specific evidence.' >&2; exit 1
fi

candidate_args=(--candidate "$candidate" --artifacts "$artifacts" --metadata "$metadata" --core-input-lock "$core_input_lock" --builder-manifest "$builder_manifest" --builder-manifest-signature "$builder_manifest_signature" --builder-attestation "$builder_attestation" --builder-attestation-signature "$builder_attestation_signature" --builder-output-tree "$builder_output_tree" --core-source "$core_source" --core-keyring "$core_keyring" --core-repository "$core_repository" --source-image "$source_image" --core-url "$core_url" --bootstrap-archive "$bootstrap_archive" --bootstrap-signature "$bootstrap_signature" --arch-snapshot-dir "$arch_snapshot_dir" --arch-keyring "$arch_keyring" --shelly-bootstrap "$shelly_bootstrap" --shelly-bootstrap-signature "$shelly_bootstrap_signature" --dependency-closure "$dependency_closure")
if [[ "$(jq -r '.edition' "$candidate")" == managed ]]; then
  candidate_args+=(--overlay-input-lock "$overlay_input_lock" --overlay-source "$overlay_source" --managed-keyring "$managed_keyring" --managed-repository "$managed_repository" --managed-url "$managed_url")
fi
bash "$script_dir/validate-candidate-lock.sh" "${candidate_args[@]}"
python3 "$script_dir/validate-json.py" "$script_dir/reproducibility-report.schema.json" "$reproducibility"
jq -e --arg set "$(jq -r '.artifactSetSha256' "$candidate")" '.outcome=="pass" and all(.builds[]; .artifactSetSha256==$set)' "$reproducibility" >/dev/null || { echo 'Reproducibility evidence does not prove this artifact set.' >&2; exit 1; }
bash "$script_dir/validate-promotion-acceptance.sh" --manifest "$acceptance" --evidence-dir "$(dirname -- "$acceptance")" --candidate "$candidate" --source-image "$source_image"
approval_args=(--approval "$approval" --signature "$approval_signature" --candidate "$candidate" --reproducibility "$reproducibility" --acceptance-manifest "$acceptance" --target-channel "$target_channel")
if [[ "$edition" == managed ]]; then approval_args+=(--edition-evidence "$edition_evidence"); fi
bash "$script_dir/validate-final-approval.sh" "${approval_args[@]}"

parent="$(dirname -- "$destination")"; [[ -d "$parent" ]] || { echo 'Promotion destination parent must exist.' >&2; exit 1; }
temporary="$(mktemp -d "$parent/.devario-promotion.XXXXXX")"; cleanup() { rm -rf -- "$temporary"; }; trap cleanup EXIT
mkdir "$temporary/artifacts" "$temporary/metadata"
cp -a -- "$artifacts/." "$temporary/artifacts/"; cp -a -- "$metadata/." "$temporary/metadata/"
if [[ "$edition" == managed ]]; then
  mkdir "$temporary/edition-evidence"
  install -m 0444 "$edition_evidence" "$temporary/edition-evidence/$edition_evidence_name"
fi
promoted_at="$(jq -r '.approvedAt' "$approval")"
jq -n --arg candidate "$(devario_sha256 "$candidate")" --arg approval "$(devario_sha256 "$approval")" --arg approvalSignature "$(devario_sha256 "$approval_signature")" \
  --arg reproducibility "$(devario_sha256 "$reproducibility")" --arg acceptance "$(devario_sha256 "$acceptance")" --arg evidence "$(devario_sha256 "$(dirname -- "$acceptance")/ACCEPTANCE.SHA256SUMS")" \
  --argjson editionEvidence "$edition_evidence_json" \
  --arg version "$(jq -r '.version' "$candidate")" --arg edition "$(jq -r '.edition' "$candidate")" --arg core "$(jq -r '.coreCommit' "$candidate")" --argjson overlay "$(jq '.overlayCommit' "$candidate")" \
  --arg from "$(jq -r '.candidateChannel' "$candidate")" --arg target "$(jq -r '.targetChannel' "$approval")" --arg promoted "$promoted_at" \
  --arg artifactSet "$(jq -r '.artifactSetSha256' "$candidate")" --arg metadataSet "$(jq -r '.metadataSetSha256' "$candidate")" \
  --argjson artifacts "$(jq '.artifacts' "$candidate")" --argjson metadata "$(jq '.metadata' "$candidate")" '
  {schemaVersion:1,candidateSha256:$candidate,approvalSha256:$approval,approvalSignatureSha256:$approvalSignature,
   reproducibilitySha256:$reproducibility,acceptanceManifestSha256:$acceptance,acceptanceEvidenceManifestSha256:$evidence,editionEvidence:$editionEvidence,
   version:$version,edition:$edition,coreCommit:$core,overlayCommit:$overlay,fromChannel:$from,targetChannel:$target,promotedAt:$promoted,
   artifactSetSha256:$artifactSet,metadataSetSha256:$metadataSet,artifacts:$artifacts,metadata:$metadata}' > "$temporary/promotion-record.json"
python3 "$script_dir/validate-json.py" "$script_dir/promotion-record.schema.json" "$temporary/promotion-record.json"
(cd "$temporary" && find . -type f ! -name PROMOTION.SHA256SUMS -printf '%P\0' | sort -z | xargs -0 sha256sum -- > PROMOTION.SHA256SUMS)
chmod 0444 "$temporary/promotion-record.json" "$temporary/PROMOTION.SHA256SUMS"
mv -- "$temporary" "$destination"; trap - EXIT
promotion_validation_args=(--destination "$destination" --record "$destination/promotion-record.json" --candidate "$candidate" --approval "$approval" --approval-signature "$approval_signature" --reproducibility "$reproducibility" --acceptance-manifest "$acceptance" --source-image "$source_image" --target-channel "$target_channel")
if [[ "$edition" == managed ]]; then promotion_validation_args+=(--edition-evidence "$edition_evidence"); fi
bash "$script_dir/validate-promotion.sh" "${promotion_validation_args[@]}"
echo "Promoted immutable candidate bytes by digest to $destination"
