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
mkdir -p "$artifacts_dir"
printf '%s\n' 'first release artifact' > "$artifacts_dir/devario-test.iso"
printf '%s\n' 'second release artifact' > "$artifacts_dir/devario-test.pkg.tar.zst"

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
  .schemaVersion == 1 and
  .edition == "community" and
  .source.coreCommit == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  .source.overlayCommit == null and
  (.subjects | length) == 2
' "$output_dir/release.json" >/dev/null

jq -e '
  .spdxVersion == "SPDX-2.3" and
  .dataLicense == "CC0-1.0" and
  (.files | length) == 2 and
  (.documentDescribes | length) == 2
' "$output_dir/release.spdx.json" >/dev/null

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
  --core-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  >"$test_root/nonempty-output.log" 2>&1; then
  echo "The generator accepted a non-empty output directory." >&2
  exit 1
fi

echo "Release metadata tests passed."
