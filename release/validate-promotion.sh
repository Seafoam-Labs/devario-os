#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; source "$script_dir/lib-release.sh"
destination='' record='' candidate='' approval='' approval_signature='' reproducibility='' acceptance='' edition_evidence='' source_image='' target_channel=''
policy="$script_dir/approval-trust-policy.json"; keyring="$script_dir/approval-keyring/release-approvers.gpg"
while (( $# )); do case "$1" in --destination) destination="$2"; shift 2;; --record) record="$2"; shift 2;; --candidate) candidate="$2"; shift 2;; --approval) approval="$2"; shift 2;; --approval-signature) approval_signature="$2"; shift 2;; --reproducibility) reproducibility="$2"; shift 2;; --acceptance-manifest) acceptance="$2"; shift 2;; --edition-evidence) edition_evidence="$2"; shift 2;; --source-image) source_image="$2"; shift 2;; --target-channel) target_channel="$2"; shift 2;; --trust-policy) policy="$2"; shift 2;; --keyring) keyring="$2"; shift 2;; *) exit 2;; esac; done
for value in destination record candidate approval approval_signature reproducibility acceptance source_image target_channel; do [[ -n "${!value}" ]] || { echo "Promotion validation missing $value; a record is not self-authenticating." >&2; exit 2; }; done
[[ -d "$destination" && "$(realpath -- "$record")" == "$(realpath -- "$destination/promotion-record.json")" ]] || { echo 'Promotion record must be canonical inside the destination.' >&2; exit 1; }
python3 "$script_dir/validate-json.py" "$script_dir/promotion-record.schema.json" "$record"
python3 "$script_dir/validate-json.py" "$script_dir/candidate-lock.schema.json" "$candidate"
python3 "$script_dir/validate-json.py" "$script_dir/reproducibility-report.schema.json" "$reproducibility"
edition="$(jq -r '.edition' "$candidate")"
edition_evidence_json='null'
if [[ "$edition" == managed ]]; then
  [[ -n "$edition_evidence" && -f "$edition_evidence" && ! -L "$edition_evidence" && -s "$edition_evidence" ]] || { echo 'Managed promotion validation requires a regular nonempty --edition-evidence file.' >&2; exit 1; }
  edition_evidence_name="$(basename -- "$edition_evidence")"
  [[ "$edition_evidence_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Managed edition-evidence basename is unsafe.' >&2; exit 1; }
  edition_evidence_json="$(jq -cn --arg name "$edition_evidence_name" --arg sha256 "$(devario_sha256 "$edition_evidence")" '{name:$name,sha256:$sha256}')"
elif [[ -n "$edition_evidence" ]]; then
  echo 'Community promotion validation rejects edition-specific evidence.' >&2; exit 1
fi
jq -e --arg candidate "$(devario_sha256 "$candidate")" --arg approval "$(devario_sha256 "$approval")" --arg signature "$(devario_sha256 "$approval_signature")" --arg reproducibility "$(devario_sha256 "$reproducibility")" --arg acceptance "$(devario_sha256 "$acceptance")" --arg evidence "$(devario_sha256 "$(dirname -- "$acceptance")/ACCEPTANCE.SHA256SUMS")" --arg target "$target_channel" '
  .candidateSha256==$candidate and .approvalSha256==$approval and .approvalSignatureSha256==$signature and
  .reproducibilitySha256==$reproducibility and .acceptanceManifestSha256==$acceptance and
  .acceptanceEvidenceManifestSha256==$evidence and .targetChannel==$target
' "$record" >/dev/null || { echo 'Promotion record evidence hashes do not match the externally supplied signed release evidence.' >&2; exit 1; }
approval_args=(--approval "$approval" --signature "$approval_signature" --candidate "$candidate" --reproducibility "$reproducibility" --acceptance-manifest "$acceptance" --target-channel "$target_channel" --trust-policy "$policy" --keyring "$keyring")
if [[ "$edition" == managed ]]; then approval_args+=(--edition-evidence "$edition_evidence"); fi
bash "$script_dir/validate-final-approval.sh" "${approval_args[@]}"
bash "$script_dir/validate-promotion-acceptance.sh" --manifest "$acceptance" --evidence-dir "$(dirname -- "$acceptance")" --candidate "$candidate" --source-image "$source_image" --trust-policy "$policy" --keyring "$keyring"
jq -e --arg set "$(jq -r '.artifactSetSha256' "$candidate")" '.outcome=="pass" and all(.builds[]; .artifactSetSha256==$set)' "$reproducibility" >/dev/null || { echo 'Promotion reproducibility report does not prove the candidate artifact set.' >&2; exit 1; }
jq -e --slurpfile candidate "$candidate" --slurpfile approval "$approval" '
  .version==$candidate[0].version and .edition==$candidate[0].edition and .coreCommit==$candidate[0].coreCommit and
  .overlayCommit==$candidate[0].overlayCommit and .fromChannel==$candidate[0].candidateChannel and
  .targetChannel==$approval[0].targetChannel and .promotedAt==$approval[0].approvedAt and
  .editionEvidence==$approval[0].editionEvidence
' "$record" >/dev/null || { echo 'Promotion record identity/channel fields differ from the signed closure.' >&2; exit 1; }
for path in artifacts metadata promotion-record.json PROMOTION.SHA256SUMS; do [[ -e "$destination/$path" && ! -L "$destination/$path" ]] || { echo "Promotion is missing $path." >&2; exit 1; }; done
mapfile -t top_entries < <(find "$destination" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
expected_top_entries=$'PROMOTION.SHA256SUMS\nartifacts\nmetadata\npromotion-record.json'
if [[ "$edition" == managed ]]; then expected_top_entries=$'PROMOTION.SHA256SUMS\nartifacts\nedition-evidence\nmetadata\npromotion-record.json'; fi
[[ "$(printf '%s\n' "${top_entries[@]}")" == "$expected_top_entries" ]] || { echo 'Promotion destination contains undeclared top-level entries.' >&2; exit 1; }
if [[ "$edition" == managed ]]; then
  [[ -d "$destination/edition-evidence" && ! -L "$destination/edition-evidence" ]] || { echo 'Managed promotion is missing its closed edition-evidence directory.' >&2; exit 1; }
  mapfile -t edition_entries < <(find "$destination/edition-evidence" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  [[ "${#edition_entries[@]}" == 1 && "${edition_entries[0]}" == "$edition_evidence_name" ]] || { echo 'Promotion contains extra or renamed edition evidence.' >&2; exit 1; }
  promoted_evidence="$destination/edition-evidence/$edition_evidence_name"
  [[ -f "$promoted_evidence" && ! -L "$promoted_evidence" && ! -w "$promoted_evidence" ]] || { echo 'Promoted edition evidence is missing, unsafe, or writable.' >&2; exit 1; }
  cmp -s "$edition_evidence" "$promoted_evidence" || { echo 'Promoted edition evidence bytes differ from the signed input.' >&2; exit 1; }
  jq -e --argjson evidence "$edition_evidence_json" '.editionEvidence==$evidence' "$record" >/dev/null || { echo 'Promotion record does not bind the supplied edition evidence.' >&2; exit 1; }
else
  jq -e '.editionEvidence==null' "$record" >/dev/null || { echo 'Community promotion record contains edition-specific evidence.' >&2; exit 1; }
fi
temporary="$(mktemp -d /tmp/devario-promotion-validate.XXXXXX)"; trap 'rm -rf -- "$temporary"' EXIT
devario_tree_json "$destination/artifacts" "$temporary/artifacts.json"; devario_tree_json "$destination/metadata" "$temporary/metadata.json"
jq -e --slurpfile tree "$temporary/artifacts.json" '.artifacts==$tree[0]' "$record" >/dev/null || { echo 'Promoted artifacts differ from record.' >&2; exit 1; }
jq -e --slurpfile tree "$temporary/metadata.json" '.metadata==$tree[0]' "$record" >/dev/null || { echo 'Promoted metadata differs from record.' >&2; exit 1; }
jq -e --slurpfile candidate "$candidate" '.artifacts==$candidate[0].artifacts and .metadata==$candidate[0].metadata and .artifactSetSha256==$candidate[0].artifactSetSha256 and .metadataSetSha256==$candidate[0].metadataSetSha256' "$record" >/dev/null || { echo 'Promotion record trees differ from the signed candidate.' >&2; exit 1; }
[[ "$(devario_tree_set_digest "$temporary/artifacts.json")" == "$(jq -r '.artifactSetSha256' "$record")" ]] || exit 1
[[ "$(devario_tree_set_digest "$temporary/metadata.json")" == "$(jq -r '.metadataSetSha256' "$record")" ]] || exit 1
(cd "$destination" && find . -type f ! -name PROMOTION.SHA256SUMS -printf '%P\0' | sort -z | xargs -0 sha256sum -- > "$temporary/PROMOTION.SHA256SUMS")
cmp -s "$temporary/PROMOTION.SHA256SUMS" "$destination/PROMOTION.SHA256SUMS" || { echo 'Promotion checksum manifest is stale or non-canonical.' >&2; exit 1; }
echo 'Validated exact digest-only promotion destination.'
