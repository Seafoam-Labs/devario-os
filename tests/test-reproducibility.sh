#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_dir/tests/lib/build-evidence-fixture.sh"
root="$(mktemp -d /tmp/devario-repro-test.XXXXXX)"; trap 'rm -rf -- "$root"' EXIT
for run in one two; do
  mkdir -p "$root/$run/artifacts" "$root/$run/builder-output"
  printf 'identical release subject\n' > "$root/$run/artifacts/devario.iso"
  printf 'identical package subject\n' > "$root/$run/artifacts/devario-base-1-1-any.pkg.tar.zst"
  cp -a "$root/$run/artifacts/." "$root/$run/builder-output/"
  create_build_evidence_fixture "$root/$run" "$root/$run/builder-output" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1786579200 "$run"
  jq -cS -n '[{name:"devario-base",version:"1-1",architecture:"any",packageBase:"devario-base",licenses:["GPL-3.0-or-later"],packager:"ZoeyErinBauer"}]' > "$root/$run/IMAGE-PACKAGE-INVENTORY.json"
  package_sha="$(sha256sum "$root/$run/artifacts/devario-base-1-1-any.pkg.tar.zst" | cut -d' ' -f1)"; package_size="$(stat -c '%s' "$root/$run/artifacts/devario-base-1-1-any.pkg.tar.zst")"
  jq -cS -n --arg binarySha "$package_sha" --argjson binarySize "$package_size" '{"$schema":"./source-index.schema.json",schemaVersion:1,packages:[{name:"devario-base",version:"1-1",architecture:"any",packageBase:"devario-base",binary:{path:"devario-base-1-1-any.pkg.tar.zst",sha256:$binarySha,size:$binarySize},sources:[{uri:"https://github.com/Seafoam-Labs/devario-os",revision:("a"*40),sha256:("1"*64),correspondingSource:true}]}]}' > "$root/$run/source-index.json"
  SOURCE_DATE_EPOCH=1786579200 DEVARIO_BUILDER_ID=https://builder.devario.example/controlled DEVARIO_INVOCATION_ID="independent-build-$run" \
    "$project_dir/release/generate-release-metadata.sh" --artifacts "$root/$run/artifacts" --output "$root/$run/metadata" \
      --edition community --version test --architecture x86_64 --channel devario-core-testing --core-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
      --installed-packages "$root/$run/IMAGE-PACKAGE-INVENTORY.json" --source-index "$root/$run/source-index.json" >/dev/null
  SOURCE_DATE_EPOCH=1786579200 "$project_dir/release/generate-candidate-lock.sh" --artifacts "$root/$run/artifacts" --metadata "$root/$run/metadata" \
    --output "$root/$run/CANDIDATE.json" --edition community --version test --architecture x86_64 --channel devario-core-testing \
    --core-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --core-input-lock "$root/$run/builder-output/CORE-INPUT-LOCK.json" \
    --builder-manifest "$root/$run/builder-output/CONTROLLED-BUILDER.json" --builder-manifest-signature "$root/$run/builder-output/CONTROLLED-BUILDER.json.sig" \
    --builder-attestation "$root/$run/builder-output/BUILDER-ATTESTATION.json" --builder-attestation-signature "$root/$run/builder-output/BUILDER-ATTESTATION.json.sig" --builder-output-tree "$root/$run/builder-output" >/dev/null
done
"$project_dir/scripts/compare-release-artifacts.sh" --first-artifacts "$root/one/artifacts" --second-artifacts "$root/two/artifacts" \
  --first-release "$root/one/metadata/release.json" --second-release "$root/two/metadata/release.json" \
  --first-candidate "$root/one/CANDIDATE.json" --second-candidate "$root/two/CANDIDATE.json" --output "$root/report.json" >/dev/null
jq -e '.outcome=="pass" and .builds[0].invocationId != .builds[1].invocationId and .builds[0].candidateLockSha256 != .builds[1].candidateLockSha256' "$root/report.json" >/dev/null
if "$project_dir/scripts/compare-release-artifacts.sh" --first-artifacts "$root/one/artifacts" --second-artifacts "$root/one/artifacts" \
  --first-release "$root/one/metadata/release.json" --second-release "$root/one/metadata/release.json" \
  --first-candidate "$root/one/CANDIDATE.json" --second-candidate "$root/one/CANDIDATE.json" --output "$root/duplicate.json" >/dev/null 2>&1; then
  echo 'Reproducibility accepted the same build twice.' >&2; exit 1
fi
echo 'Reproducibility tests passed.'
