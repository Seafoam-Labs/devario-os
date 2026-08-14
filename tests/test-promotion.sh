#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_dir/release/lib-release.sh"
root="$(mktemp -d /tmp/devario-promotion-test.XXXXXX)"; trap 'rm -rf -- "$root"' EXIT
destination="$root/stable"; mkdir -p "$destination/artifacts" "$destination/metadata"
printf 'immutable artifact\n' > "$destination/artifacts/devario.iso"
printf '{}\n' > "$destination/metadata/release.json"
devario_tree_json "$destination/artifacts" "$root/artifacts.json"
devario_tree_json "$destination/metadata" "$root/metadata.json"
artifact_set="$(devario_tree_set_digest "$root/artifacts.json")"; metadata_set="$(devario_tree_set_digest "$root/metadata.json")"
jq -n --arg artifactSet "$artifact_set" --arg metadataSet "$metadata_set" --slurpfile artifacts "$root/artifacts.json" --slurpfile metadata "$root/metadata.json" '{schemaVersion:1,candidateSha256:("1"*64),approvalSha256:("2"*64),approvalSignatureSha256:("3"*64),reproducibilitySha256:("4"*64),acceptanceManifestSha256:("5"*64),acceptanceEvidenceManifestSha256:("6"*64),editionEvidence:null,version:"test",edition:"community",coreCommit:("a"*40),overlayCommit:null,fromChannel:"devario-core-testing",targetChannel:"devario-core-stable",promotedAt:"2026-08-13T02:00:00Z",artifactSetSha256:$artifactSet,metadataSetSha256:$metadataSet,artifacts:$artifacts[0],metadata:$metadata[0]}' > "$destination/promotion-record.json"
(cd "$destination" && find . -type f ! -name PROMOTION.SHA256SUMS -printf '%P\0' | sort -z | xargs -0 sha256sum -- > PROMOTION.SHA256SUMS)
jq '.editionEvidence={name:"managed-lock.json",sha256:("7"*64)}' "$destination/promotion-record.json" > "$root/community-with-edition-evidence.json"
if python3 "$project_dir/release/validate-json.py" "$project_dir/release/promotion-record.schema.json" "$root/community-with-edition-evidence.json" >/dev/null 2>&1; then
  echo 'Community promotion schema accepted edition-specific evidence.' >&2; exit 1
fi
jq '.edition="managed" | .overlayCommit=("b"*40) | .fromChannel="devario-managed-pilot" | .targetChannel="devario-managed-stable"' "$destination/promotion-record.json" > "$root/managed-without-edition-evidence.json"
if python3 "$project_dir/release/validate-json.py" "$project_dir/release/promotion-record.schema.json" "$root/managed-without-edition-evidence.json" >/dev/null 2>&1; then
  echo 'Managed promotion schema accepted missing edition evidence.' >&2; exit 1
fi
if "$project_dir/release/validate-promotion.sh" --destination "$destination" --record "$destination/promotion-record.json" >/dev/null 2>&1; then
  echo 'Promotion validation accepted a self-authored record without signed external evidence.' >&2; exit 1
fi
echo 'Promotion forged-record rejection test passed.'
