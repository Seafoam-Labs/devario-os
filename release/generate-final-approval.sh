#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; source "$script_dir/lib-release.sh"
candidate='' reproducibility='' acceptance='' edition_evidence='' target='' fingerprint='' output=''
while (( $# )); do case "$1" in --candidate) candidate="$2"; shift 2;; --reproducibility) reproducibility="$2"; shift 2;; --acceptance-manifest) acceptance="$2"; shift 2;; --edition-evidence) edition_evidence="$2"; shift 2;; --target-channel) target="$2"; shift 2;; --approver-fingerprint) fingerprint="${2^^}"; shift 2;; --output) output="$2"; shift 2;; *) exit 2;; esac; done
for value in candidate reproducibility acceptance target fingerprint output; do [[ -n "${!value}" ]] || exit 2; done
[[ "$fingerprint" =~ ^[0-9A-F]{40}([0-9A-F]{24})?$ ]] || { echo 'Approver fingerprint must be a full primary fingerprint.' >&2; exit 1; }
[[ ! -e "$output" ]] || { echo 'Approval output already exists.' >&2; exit 1; }
python3 "$script_dir/validate-json.py" "$script_dir/candidate-lock.schema.json" "$candidate"
python3 "$script_dir/validate-json.py" "$script_dir/reproducibility-report.schema.json" "$reproducibility"
python3 "$script_dir/validate-json.py" "$script_dir/promotion-acceptance.schema.json" "$acceptance"
jq -e '.outcome == "pass"' "$reproducibility" >/dev/null || { echo 'Reproducibility did not pass.' >&2; exit 1; }
candidate_sha="$(devario_sha256 "$candidate")"; artifact_set="$(jq -r '.artifactSetSha256' "$candidate")"
jq -e --arg set "$artifact_set" 'all(.builds[]; .artifactSetSha256==$set)' "$reproducibility" >/dev/null || { echo 'Reproducibility does not prove this candidate artifact set.' >&2; exit 1; }
jq -e --arg candidate "$candidate_sha" --arg version "$(jq -r '.version' "$candidate")" --arg edition "$(jq -r '.edition' "$candidate")" '.candidateSha256==$candidate and .candidateVersion==$version and .edition==$edition' "$acceptance" >/dev/null || { echo 'Acceptance manifest targets another candidate identity.' >&2; exit 1; }
edition="$(jq -r '.edition' "$candidate")"; from="$(jq -r '.candidateChannel' "$candidate")"
if [[ "$edition:$from:$target" != community:devario-core-testing:devario-core-stable \
  && "$edition:$from:$target" != managed:devario-managed-pilot:devario-managed-stable ]]; then
  echo 'Requested promotion is not an allowed edition/channel transition.' >&2; exit 1
fi
edition_evidence_json='null'
if [[ "$edition" == managed ]]; then
  [[ -n "$edition_evidence" && -f "$edition_evidence" && ! -L "$edition_evidence" && -s "$edition_evidence" ]] || { echo 'Managed approval requires a regular nonempty --edition-evidence file.' >&2; exit 1; }
  edition_evidence_name="$(basename -- "$edition_evidence")"
  [[ "$edition_evidence_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Managed edition-evidence basename is unsafe.' >&2; exit 1; }
  edition_evidence_json="$(jq -cn --arg name "$edition_evidence_name" --arg sha256 "$(devario_sha256 "$edition_evidence")" '{name:$name,sha256:$sha256}')"
elif [[ -n "$edition_evidence" ]]; then
  echo 'Community approval rejects edition-specific evidence.' >&2; exit 1
fi
evidence="$acceptance"; evidence_dir="$(dirname -- "$evidence")"; sums="$evidence_dir/ACCEPTANCE.SHA256SUMS"
[[ -f "$sums" ]] || { echo 'Acceptance evidence manifest is missing.' >&2; exit 1; }
approved_at="${DEVARIO_APPROVED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
temporary="$(mktemp /tmp/devario-final-approval.XXXXXX)"; trap 'rm -f -- "$temporary"' EXIT
jq -n --arg candidate "$candidate_sha" --arg version "$(jq -r '.version' "$candidate")" --arg edition "$(jq -r '.edition' "$candidate")" \
  --arg core "$(jq -r '.coreCommit' "$candidate")" --argjson overlay "$(jq '.overlayCommit' "$candidate")" \
  --arg from "$from" --arg target "$target" --arg artifacts "$(jq -r '.artifactSetSha256' "$candidate")" \
  --argjson editionEvidence "$edition_evidence_json" \
  --arg reproducibility "$(devario_sha256 "$reproducibility")" --arg acceptance "$(devario_sha256 "$acceptance")" --arg sums "$(devario_sha256 "$sums")" \
  --arg fingerprint "$fingerprint" --arg approvedAt "$approved_at" '
  {schemaVersion:1,candidateSha256:$candidate,version:$version,edition:$edition,coreCommit:$core,overlayCommit:$overlay,
   fromChannel:$from,targetChannel:$target,artifactSetSha256:$artifacts,editionEvidence:$editionEvidence,reproducibility:{sha256:$reproducibility},
   acceptance:{manifestSha256:$acceptance,evidenceManifestSha256:$sums},approver:"ZoeyErinBauer",
   approverFingerprint:$fingerprint,approvedAt:$approvedAt,decision:"approve"}' > "$temporary"
python3 "$script_dir/validate-json.py" "$script_dir/final-approval.schema.json" "$temporary"
install -m 0444 "$temporary" "$output"
echo "Generated unsigned approval template for ZoeyErinBauer: $output"
echo 'Sign this exact file with the separately controlled active approval key.'
