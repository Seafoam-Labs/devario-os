#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
source "$project_dir/release/lib-release.sh"
first='' second='' first_release='' second_release='' first_candidate='' second_candidate='' output=''
while (( $# )); do
  case "$1" in
    --first-artifacts) first="$2"; shift 2 ;;
    --second-artifacts) second="$2"; shift 2 ;;
    --first-release) first_release="$2"; shift 2 ;;
    --second-release) second_release="$2"; shift 2 ;;
    --first-candidate) first_candidate="$2"; shift 2 ;;
    --second-candidate) second_candidate="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    *) echo 'Usage: compare-release-artifacts.sh --first-artifacts DIR --second-artifacts DIR --first-release FILE --second-release FILE --first-candidate FILE --second-candidate FILE --output FILE' >&2; exit 2 ;;
  esac
done
for value in first second first_release second_release first_candidate second_candidate output; do [[ -n "${!value}" ]] || { echo "Missing $value." >&2; exit 2; }; done
[[ ! -e "$output" ]] || { echo "Output already exists: $output" >&2; exit 1; }
python3 "$project_dir/release/validate-json.py" "$project_dir/release/release-metadata.schema.json" "$first_release"
python3 "$project_dir/release/validate-json.py" "$project_dir/release/release-metadata.schema.json" "$second_release"
python3 "$project_dir/release/validate-json.py" "$project_dir/release/candidate-lock.schema.json" "$first_candidate"
python3 "$project_dir/release/validate-json.py" "$project_dir/release/candidate-lock.schema.json" "$second_candidate"
temp_dir="$(mktemp -d /tmp/devario-reproducibility.XXXXXX)"; trap 'rm -rf -- "$temp_dir"' EXIT
devario_tree_json "$(realpath -- "$first")" "$temp_dir/first.json"
devario_tree_json "$(realpath -- "$second")" "$temp_dir/second.json"
first_set="$(devario_tree_set_digest "$temp_dir/first.json")"; second_set="$(devario_tree_set_digest "$temp_dir/second.json")"
first_subjects="$(jq -cS '.subjects' "$first_release")"; second_subjects="$(jq -cS '.subjects' "$second_release")"
actual_first_subjects="$(jq -cS '[.[]|select(.mode != "120000")|{name:.path,digest:{sha256:.sha256},size:.size}]' "$temp_dir/first.json")"
actual_second_subjects="$(jq -cS '[.[]|select(.mode != "120000")|{name:.path,digest:{sha256:.sha256},size:.size}]' "$temp_dir/second.json")"
first_candidate_sha="$(devario_sha256 "$first_candidate")"; second_candidate_sha="$(devario_sha256 "$second_candidate")"
first_invocation="$(jq -r '.build.invocationId' "$first_release")"; second_invocation="$(jq -r '.build.invocationId' "$second_release")"
identity_filter='{edition,version,architecture,candidateChannel,coreCommit,overlayCommit,sourceDateEpoch,coreInputLock:.buildEvidence.coreInputLock.sha256,overlayInputLock:(.buildEvidence.overlayInputLock.sha256 // null)}'
first_identity="$(jq -cS "$identity_filter" "$first_candidate")"; second_identity="$(jq -cS "$identity_filter" "$second_candidate")"
release_identity_filter='{edition,version,architecture,channel,sourceDateEpoch,source,imagePackageInventory,correspondingSourceIndex}'
first_release_identity="$(jq -cS "$release_identity_filter" "$first_release")"
second_release_identity="$(jq -cS "$release_identity_filter" "$second_release")"
outcome=pass
if ! cmp -s "$temp_dir/first.json" "$temp_dir/second.json" \
  || [[ "$first_subjects" != "$second_subjects" || "$first_set" != "$second_set" \
    || "$first_candidate_sha" == "$second_candidate_sha" || "$first_invocation" == "$second_invocation" \
    || "$first_identity" != "$second_identity" || "$first_release_identity" != "$second_release_identity" \
    || "$first_subjects" != "$actual_first_subjects" \
    || "$second_subjects" != "$actual_second_subjects" ]]; then outcome=fail; fi
candidate_matches_run() {
  local lock="$1" tree="$2" set_digest="$3" release="$4"
  jq -e --slurpfile actual "$tree" --arg set "$set_digest" \
    '.artifacts==$actual[0] and .artifactSetSha256==$set' "$lock" >/dev/null \
    && jq -e --slurpfile lock "$lock" '
      .edition==$lock[0].edition and .version==$lock[0].version and
      .architecture==$lock[0].architecture and .channel==$lock[0].candidateChannel and
      .sourceDateEpoch==$lock[0].sourceDateEpoch and
      .source.coreCommit==$lock[0].coreCommit and .source.overlayCommit==$lock[0].overlayCommit
    ' "$release" >/dev/null
}
candidate_matches_run "$first_candidate" "$temp_dir/first.json" "$first_set" "$first_release" || outcome=fail
candidate_matches_run "$second_candidate" "$temp_dir/second.json" "$second_set" "$second_release" || outcome=fail
subject_digest="$(printf '%s\n' "$first_subjects" | sha256sum | cut -d' ' -f1)"
identity_digest="$(printf '%s\n%s\n' "$first_identity" "$first_release_identity" | sha256sum | cut -d' ' -f1)"
mkdir -p -- "$(dirname -- "$output")"
jq -n --arg outcome "$outcome" --arg subjects "$subject_digest" --arg identity "$identity_digest" \
  --argjson count "$(jq '[.[] | select(.mode != "120000")] | length' "$temp_dir/first.json")" \
  --arg firstRelease "$(devario_sha256 "$first_release")" --arg secondRelease "$(devario_sha256 "$second_release")" \
  --arg firstCandidate "$first_candidate_sha" --arg secondCandidate "$second_candidate_sha" \
  --arg firstSet "$first_set" --arg secondSet "$second_set" \
  --arg firstBuilder "$(jq -r '.build.builderId' "$first_release")" --arg secondBuilder "$(jq -r '.build.builderId' "$second_release")" \
  --arg firstInvocation "$first_invocation" --arg secondInvocation "$second_invocation" \
  --arg firstCoreLock "$(jq -r '.buildEvidence.coreInputLock.sha256' "$first_candidate")" --arg secondCoreLock "$(jq -r '.buildEvidence.coreInputLock.sha256' "$second_candidate")" \
  --argjson firstOverlayLock "$(jq '.buildEvidence.overlayInputLock.sha256 // null' "$first_candidate")" --argjson secondOverlayLock "$(jq '.buildEvidence.overlayInputLock.sha256 // null' "$second_candidate")" '
  {schemaVersion:1,outcome:$outcome,subjectSetSha256:$subjects,subjectIdentitySha256:$identity,comparedSubjects:$count,
   builds:[
    {releaseMetadataSha256:$firstRelease,candidateLockSha256:$firstCandidate,artifactSetSha256:$firstSet,builderId:$firstBuilder,invocationId:$firstInvocation,coreInputLockSha256:$firstCoreLock,overlayInputLockSha256:$firstOverlayLock},
    {releaseMetadataSha256:$secondRelease,candidateLockSha256:$secondCandidate,artifactSetSha256:$secondSet,builderId:$secondBuilder,invocationId:$secondInvocation,coreInputLockSha256:$secondCoreLock,overlayInputLockSha256:$secondOverlayLock}],
   excludedPerRunMetadata:["provenance.intoto.json:predicate.runDetails"]}' > "$temp_dir/report.json"
python3 "$project_dir/release/validate-json.py" "$project_dir/release/reproducibility-report.schema.json" "$temp_dir/report.json"
install -m 0444 "$temp_dir/report.json" "$output"
if [[ "$outcome" != pass ]]; then
  echo 'Independent build artifacts or deterministic subjects differ.' >&2; exit 1
fi
echo "Reproducibility passed for $(jq '[.[] | select(.mode != "120000")] | length' "$temp_dir/first.json") deterministic subjects."
