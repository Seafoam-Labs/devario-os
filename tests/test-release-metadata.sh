#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
generator="$project_dir/release/generate-release-metadata.sh"

for command_name in jq sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required test command: $command_name" >&2
    exit 1
  fi
done

test_root="$(mktemp -d /tmp/devario-release-metadata-test.XXXXXX)"
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

artifacts_dir="$test_root/artifacts"
output_dir="$test_root/metadata"
mkdir -p "$artifacts_dir/core"
printf '%s\n' 'first release artifact' > "$artifacts_dir/devario-test.iso"
printf '%s\n' 'second release artifact' > "$artifacts_dir/core/devario-test.pkg.tar.zst"
jq -cS -n '[{name:"devario-base",version:"1-1",architecture:"any",packageBase:"devario-base",licenses:["GPL-3.0-or-later"],packager:"ZoeyErinBauer"}]' > "$test_root/IMAGE-PACKAGE-INVENTORY.json"
package_sha="$(sha256sum "$artifacts_dir/core/devario-test.pkg.tar.zst" | cut -d' ' -f1)"
package_size="$(stat -c '%s' "$artifacts_dir/core/devario-test.pkg.tar.zst")"
jq -cS -n --arg binarySha "$package_sha" --argjson binarySize "$package_size" '{"$schema":"./source-index.schema.json",schemaVersion:1,packages:[{name:"devario-base",version:"1-1",architecture:"any",packageBase:"devario-base",binary:{path:"core/devario-test.pkg.tar.zst",sha256:$binarySha,size:$binarySize},sources:[{uri:"https://github.com/Seafoam-Labs/devario-os",revision:("a"*40),sha256:("1"*64),correspondingSource:true}]}]}' > "$test_root/source-index.json"

SOURCE_DATE_EPOCH=1786579200 \
DEVARIO_BUILDER_ID='https://github.com/Seafoam-Labs/devario-os/actions/test' \
DEVARIO_INVOCATION_ID='release-metadata-self-test' \
  bash "$generator" \
    --artifacts "$artifacts_dir" \
    --output "$output_dir" \
    --edition community \
    --version 0.0.0-test \
    --architecture x86_64 \
    --channel devario-core-testing \
    --installed-packages "$test_root/IMAGE-PACKAGE-INVENTORY.json" \
    --source-index "$test_root/source-index.json" \
    --core-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

(
  cd "$artifacts_dir"
  sha256sum -c "$output_dir/SHA256SUMS"
)
(
  cd "$output_dir"
  sha256sum -c METADATA.SHA256SUMS
)

jq -e '
  .schemaVersion == 2 and
  .edition == "community" and
  .sourceDateEpoch == 1786579200 and
  .build.builderId == "https://github.com/Seafoam-Labs/devario-os/actions/test" and
  .build.invocationId == "release-metadata-self-test" and
  .source.coreCommit == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  .source.overlayCommit == null and
  (.subjects | length) == 2
' "$output_dir/release.json" >/dev/null
python3 "$project_dir/release/validate-json.py" "$project_dir/release/release-metadata.schema.json" "$output_dir/release.json"

jq -e '
  .spdxVersion == "SPDX-2.3" and
  .dataLicense == "CC0-1.0" and
  (.files | length) == 2 and
  (.documentDescribes | length) == 2
' "$output_dir/release.spdx.json" >/dev/null
jq -e '.packages[0].name=="devario-base" and .packages[0].versionInfo=="1-1" and (.packages[0].comment|contains("correspondingSource="))' "$output_dir/installed-packages.spdx.json" >/dev/null
jq -e '.creationInfo.creators[0] == "Person: ZoeyErinBauer"' "$output_dir/release.spdx.json" >/dev/null

jq -e '
  ._type == "https://in-toto.io/Statement/v1" and
  .predicateType == "https://slsa.dev/provenance/v1" and
  (.subject | length) == 2 and
  .predicate.buildDefinition.externalParameters.channel == "devario-core-testing"
' "$output_dir/provenance.intoto.json" >/dev/null

jq -e '
  .schemaVersion == 1 and
  (.artifacts | length) == 6 and
  all(.artifacts[]; (.sha256 | test("^[0-9a-f]{64}$")) and .correspondingSource)
' "$project_dir/release/source-manifest.json" >/dev/null

if find "$output_dir" -maxdepth 1 -type f -name '*.sig' -print -quit | grep -q .; then
  echo "The keyless metadata generator unexpectedly created a signature." >&2
  exit 1
fi

if bash "$generator" \
  --artifacts "$artifacts_dir" \
  --output "$output_dir" \
  --edition community \
  --version 0.0.0-test \
  --architecture x86_64 \
  --channel devario-core-testing \
  --installed-packages "$test_root/IMAGE-PACKAGE-INVENTORY.json" \
  --source-index "$test_root/source-index.json" \
  --core-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  >"$test_root/nonempty-output.log" 2>&1; then
  echo "The generator accepted a non-empty output directory." >&2
  exit 1
fi

duplicate_json="$test_root/duplicate.json"
printf '%s\n' '{"schemaVersion":2,"schemaVersion":2}' > "$duplicate_json"
if python3 "$project_dir/release/validate-json.py" "$project_dir/release/release-metadata.schema.json" "$duplicate_json" >/dev/null 2>&1; then
  echo 'Strict JSON validation accepted a duplicate object key.' >&2
  exit 1
fi
duplicate_schema="$test_root/duplicate-schema.json"
printf '%s\n' '{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","type":"array"}' > "$duplicate_schema"
if python3 "$project_dir/release/validate-json.py" "$duplicate_schema" "$output_dir/release.json" >/dev/null 2>&1; then
  echo 'Strict JSON validation accepted a duplicate schema object key.' >&2
  exit 1
fi

unset DEVARIO_BUILDER_ID DEVARIO_INVOCATION_ID
empty_output="$test_root/missing-controlled-id"
if SOURCE_DATE_EPOCH=1786579200 bash "$generator" --artifacts "$artifacts_dir" --output "$empty_output" \
  --edition community --version 0.0.0-test --architecture x86_64 --channel devario-core-testing \
  --installed-packages "$test_root/IMAGE-PACKAGE-INVENTORY.json" --source-index "$test_root/source-index.json" \
  --core-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null 2>&1; then
  echo 'Generator accepted release metadata without explicit controlled build identity.' >&2
  exit 1
fi

jq -cS '.packages[0].binary.sha256 = ("f" * 64)' "$test_root/source-index.json" > "$test_root/stale-source-index.json"
if SOURCE_DATE_EPOCH=1786579200 \
  DEVARIO_BUILDER_ID='https://github.com/Seafoam-Labs/devario-os/actions/test' \
  DEVARIO_INVOCATION_ID='release-metadata-stale-source-test' \
  bash "$generator" --artifacts "$artifacts_dir" --output "$test_root/stale-source-output" \
    --edition community --version 0.0.0-test --architecture x86_64 --channel devario-core-testing \
    --installed-packages "$test_root/IMAGE-PACKAGE-INVENTORY.json" --source-index "$test_root/stale-source-index.json" \
    --core-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null 2>&1; then
  echo 'Generator accepted a stale binary-to-source binding.' >&2
  exit 1
fi

for invalid_version in '1.0+managed' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
  invalid_output="$test_root/invalid-version-${#invalid_version}"
  if SOURCE_DATE_EPOCH=1786579200 \
    DEVARIO_BUILDER_ID='https://github.com/Seafoam-Labs/devario-os/actions/test' \
    DEVARIO_INVOCATION_ID='release-metadata-invalid-version-test' \
    bash "$generator" --artifacts "$artifacts_dir" --output "$invalid_output" \
      --edition community --version "$invalid_version" --architecture x86_64 --channel devario-core-testing \
      --installed-packages "$test_root/IMAGE-PACKAGE-INVENTORY.json" --source-index "$test_root/source-index.json" \
      --core-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null 2>&1; then
    echo "Generator accepted noncanonical release version: $invalid_version" >&2
    exit 1
  fi
done

echo "Release metadata tests passed."
