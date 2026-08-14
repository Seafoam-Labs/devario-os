#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; source "$script_dir/lib-release.sh"
approval='' signature='' candidate='' reproducibility='' acceptance='' edition_evidence='' target_channel=''
policy="$script_dir/approval-trust-policy.json"; keyring="$script_dir/approval-keyring/release-approvers.gpg"
while (( $# )); do case "$1" in --approval) approval="$2"; shift 2;; --signature) signature="$2"; shift 2;; --candidate) candidate="$2"; shift 2;; --reproducibility) reproducibility="$2"; shift 2;; --acceptance-manifest) acceptance="$2"; shift 2;; --edition-evidence) edition_evidence="$2"; shift 2;; --target-channel) target_channel="$2"; shift 2;; --trust-policy) policy="$2"; shift 2;; --keyring) keyring="$2"; shift 2;; *) exit 2;; esac; done
for value in approval signature candidate reproducibility acceptance target_channel; do [[ -n "${!value}" ]] || exit 2; done
python3 "$script_dir/validate-json.py" "$script_dir/final-approval.schema.json" "$approval"
python3 "$script_dir/validate-json.py" "$script_dir/candidate-lock.schema.json" "$candidate"
python3 "$script_dir/validate-json.py" "$script_dir/reproducibility-report.schema.json" "$reproducibility"
python3 "$script_dir/validate-json.py" "$script_dir/promotion-acceptance.schema.json" "$acceptance"
bash "$script_dir/validate-trust-policy.sh" --policy "$policy" --keyring "$keyring" --purpose human-release-approval
edition="$(jq -r '.edition' "$candidate")"; from="$(jq -r '.candidateChannel' "$candidate")"
if [[ "$edition:$from:$target_channel" != community:devario-core-testing:devario-core-stable \
  && "$edition:$from:$target_channel" != managed:devario-managed-pilot:devario-managed-stable ]]; then
  echo 'Final approval requests a forbidden edition/channel transition.' >&2; exit 1
fi
edition_evidence_json='null'
if [[ "$edition" == managed ]]; then
  [[ -n "$edition_evidence" && -f "$edition_evidence" && ! -L "$edition_evidence" && -s "$edition_evidence" ]] || { echo 'Managed final approval requires a regular nonempty --edition-evidence file.' >&2; exit 1; }
  edition_evidence_name="$(basename -- "$edition_evidence")"
  [[ "$edition_evidence_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Managed edition-evidence basename is unsafe.' >&2; exit 1; }
  edition_evidence_json="$(jq -cn --arg name "$edition_evidence_name" --arg sha256 "$(devario_sha256 "$edition_evidence")" '{name:$name,sha256:$sha256}')"
elif [[ -n "$edition_evidence" ]]; then
  echo 'Community final approval rejects edition-specific evidence.' >&2; exit 1
fi
sums="$(dirname -- "$acceptance")/ACCEPTANCE.SHA256SUMS"; [[ -f "$sums" ]] || { echo 'Acceptance evidence manifest is missing.' >&2; exit 1; }
candidate_sha="$(devario_sha256 "$candidate")"; artifact_set="$(jq -r '.artifactSetSha256' "$candidate")"
jq -e --arg set "$artifact_set" '.outcome=="pass" and all(.builds[]; .artifactSetSha256==$set)' "$reproducibility" >/dev/null || { echo 'Reproducibility does not prove this candidate artifact set.' >&2; exit 1; }
jq -e --arg candidate "$candidate_sha" --arg version "$(jq -r '.version' "$candidate")" --arg edition "$edition" '.candidateSha256==$candidate and .candidateVersion==$version and .edition==$edition' "$acceptance" >/dev/null || { echo 'Acceptance manifest targets another candidate identity.' >&2; exit 1; }
jq -e --arg candidate "$candidate_sha" --arg edition "$edition" \
  --arg version "$(jq -r '.version' "$candidate")" --arg core "$(jq -r '.coreCommit' "$candidate")" --arg artifacts "$(jq -r '.artifactSetSha256' "$candidate")" \
  --argjson overlay "$(jq '.overlayCommit' "$candidate")" --arg from "$(jq -r '.candidateChannel' "$candidate")" --arg target "$target_channel" \
  --argjson editionEvidence "$edition_evidence_json" \
  --arg reproducibility "$(devario_sha256 "$reproducibility")" --arg acceptance "$(devario_sha256 "$acceptance")" --arg sums "$(devario_sha256 "$sums")" '
  .candidateSha256==$candidate and .version==$version and .edition==$edition and .coreCommit==$core and .overlayCommit==$overlay and
  .fromChannel==$from and .targetChannel==$target and .artifactSetSha256==$artifacts and .editionEvidence==$editionEvidence and
  .reproducibility.sha256==$reproducibility and .acceptance.manifestSha256==$acceptance and .acceptance.evidenceManifestSha256==$sums
  ' "$approval" >/dev/null || { echo 'Final approval bindings do not match the supplied release evidence.' >&2; exit 1; }
active="$(jq -r '.activeFingerprint // empty' "$policy")"
[[ -n "$active" && "$(jq -r '.purpose' "$policy")" == human-release-approval ]] || { echo 'Fixed human approval trust is not provisioned.' >&2; exit 1; }
[[ "$(jq -r '.approverFingerprint' "$approval")" == "$active" ]] || { echo 'Approval fingerprint is not the current fixed approver.' >&2; exit 1; }
status="$(gpgv --status-fd 1 --keyring "$keyring" "$signature" "$approval" 2>/dev/null)" || { echo 'Final approval signature is invalid.' >&2; exit 1; }
signer="$(awk '/^\[GNUPG:\] VALIDSIG / {print ($NF ~ /^[0-9A-F]{40,64}$/ ? $NF : $3); exit}' <<<"$status")"
[[ "$signer" == "$active" ]] || { echo 'Final approval signature did not use the active fixed approver key.' >&2; exit 1; }
echo "Validated final signed approval by ZoeyErinBauer ($active)."
