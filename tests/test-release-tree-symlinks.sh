#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../release/lib-release.sh
source "$project_dir/release/lib-release.sh"
root="$(mktemp -d /tmp/devario-release-tree-test.XXXXXX)"
trap 'rm -rf -- "$root"' EXIT
tree="$root/artifacts"
mkdir -p "$tree/repositories/core" "$tree/repositories/managed"
printf 'release image\n' > "$tree/devario.iso"

create_repository_layout() {
  local directory="$1" repository="$2" suffix
  for suffix in db.tar.zst files.tar.zst db.tar.zst.sig files.tar.zst.sig; do
    printf '%s %s\n' "$repository" "$suffix" > "$directory/$repository.$suffix"
  done
  ln -s "$repository.db.tar.zst" "$directory/$repository.db"
  ln -s "$repository.files.tar.zst" "$directory/$repository.files"
  ln -s "$repository.db.tar.zst.sig" "$directory/$repository.db.sig"
  ln -s "$repository.files.tar.zst.sig" "$directory/$repository.files.sig"
}

create_repository_layout "$tree/repositories/core" devario-core
create_repository_layout "$tree/repositories/managed" devario-managed
devario_tree_json "$tree" "$root/tree.json"
jq -e '
  length == 17 and
  ([.[] | select(.mode == "120000")] | length) == 8 and
  all(.[] | select(.mode == "120000");
    has("target") and (has("sha256") | not) and (has("size") | not)
  ) and
  any(.[];
    .path == "repositories/core/devario-core.db.sig" and
    .mode == "120000" and .target == "devario-core.db.tar.zst.sig"
  ) and
  any(.[];
    .path == "repositories/managed/devario-managed.files" and
    .mode == "120000" and .target == "devario-managed.files.tar.zst"
  )
' "$root/tree.json" >/dev/null

tree_digest="$(devario_tree_set_digest "$root/tree.json")"
for mutation in \
  '(.[] | select(.path=="repositories/core/devario-core.db")).path="repositories/core/devario-core.files"' \
  '(.[] | select(.path=="repositories/core/devario-core.db")).mode="120001"' \
  '(.[] | select(.path=="repositories/core/devario-core.db")).target="devario-core.files.tar.zst"'; do
  jq "$mutation" "$root/tree.json" > "$root/mutated.json"
  [[ "$(devario_tree_set_digest "$root/mutated.json")" != "$tree_digest" ]] || {
    echo 'Release tree set digest did not bind a repository-link field.' >&2
    exit 1
  }
done

jq -n --slurpfile artifacts "$root/tree.json" '{
  schemaVersion:2,edition:"community",version:"test",architecture:"x86_64",
  candidateChannel:"devario-core-testing",coreCommit:("a"*40),overlayCommit:null,
  sourceDateEpoch:1786579200,createdAt:"2026-08-13T00:00:00Z",
  artifacts:$artifacts[0],artifactSetSha256:("1"*64),
  metadata:[{path:"release.json",sha256:("2"*64),size:1,mode:"644"}],metadataSetSha256:("3"*64),
  buildEvidence:{coreInputLock:{name:"CORE-INPUT-LOCK.json",sha256:("4"*64)},overlayInputLock:null,
    builderManifest:{name:"CONTROLLED-BUILDER.json",sha256:("5"*64)},builderManifestSignature:{name:"CONTROLLED-BUILDER.json.sig",sha256:("6"*64)},
    builderAttestation:{name:"BUILDER-ATTESTATION.json",sha256:("7"*64)},builderAttestationSignature:{name:"BUILDER-ATTESTATION.json.sig",sha256:("8"*64)}}
}' > "$root/candidate.json"
python3 "$project_dir/release/validate-json.py" "$project_dir/release/candidate-lock.schema.json" "$root/candidate.json"
jq -n --slurpfile artifacts "$root/tree.json" '{
  schemaVersion:1,candidateSha256:("1"*64),approvalSha256:("2"*64),approvalSignatureSha256:("3"*64),
  reproducibilitySha256:("4"*64),acceptanceManifestSha256:("5"*64),acceptanceEvidenceManifestSha256:("6"*64),
  editionEvidence:null,version:"test",edition:"community",coreCommit:("a"*40),overlayCommit:null,
  fromChannel:"devario-core-testing",targetChannel:"devario-core-stable",promotedAt:"2026-08-13T00:00:00Z",
  artifactSetSha256:("7"*64),metadataSetSha256:("8"*64),artifacts:$artifacts[0],
  metadata:[{path:"release.json",sha256:("9"*64),size:1,mode:"644"}]
}' > "$root/promotion-record.json"
python3 "$project_dir/release/validate-json.py" "$project_dir/release/promotion-record.schema.json" "$root/promotion-record.json"
jq '(.artifacts[] | select(.path=="repositories/core/devario-core.db")).target="devario-managed.db.tar.zst"' \
  "$root/candidate.json" > "$root/cross-target-candidate.json"
if python3 "$project_dir/release/validate-json.py" "$project_dir/release/candidate-lock.schema.json" \
  "$root/cross-target-candidate.json" >/dev/null 2>&1; then
  echo 'Candidate schema accepted a repository link with a substituted target.' >&2
  exit 1
fi

ln -s devario.iso "$tree/extra-link"
if devario_require_closed_tree "$tree" >/dev/null 2>&1; then
  echo 'Release tree accepted a non-repository symlink.' >&2
  exit 1
fi
rm "$tree/extra-link"

rm "$tree/repositories/core/devario-core.db"
ln -s ../devario-core.db.tar.zst "$tree/repositories/core/devario-core.db"
if devario_require_closed_tree "$tree" >/dev/null 2>&1; then
  echo 'Release tree accepted an escaping canonical-name symlink.' >&2
  exit 1
fi
rm "$tree/repositories/core/devario-core.db"
ln -s devario-core.db.tar.zst "$tree/repositories/core/devario-core.db"

rm "$tree/repositories/managed/devario-managed.files.sig"
if devario_require_closed_tree "$tree" >/dev/null 2>&1; then
  echo 'Release tree accepted an incomplete signed repo-add link set.' >&2
  exit 1
fi
ln -s devario-managed.files.tar.zst.sig "$tree/repositories/managed/devario-managed.files.sig"

rm "$tree/repositories/core/devario-core.db.tar.zst.sig"
if devario_require_closed_tree "$tree" >/dev/null 2>&1; then
  echo 'Release tree accepted a canonical link whose target member is missing.' >&2
  exit 1
fi

echo 'Release-tree canonical repository symlink tests passed.'
