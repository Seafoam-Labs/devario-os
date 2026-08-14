#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_dir/tests/lib/build-evidence-fixture.sh"
if grep -Fq 'validate-managed-input-lock.sh' "$project_dir/release/validate-candidate-lock.sh"; then
  echo 'Candidate validation conflates the ISO CORE lock with the external-package CORE lock.' >&2
  exit 1
fi
root="$(mktemp -d /tmp/devario-candidate-test.XXXXXX)"; trap 'rm -rf -- "$root"' EXIT
artifacts="$root/artifacts"; builder_output="$root/builder-output"; metadata="$root/metadata"; mkdir "$artifacts" "$builder_output"
printf 'candidate iso\n' > "$artifacts/devario-test.iso"
printf 'candidate package\n' > "$artifacts/devario-base-1-1-any.pkg.tar.zst"
mkdir -p "$artifacts/repositories/core"
for suffix in db.tar.zst files.tar.zst db.tar.zst.sig files.tar.zst.sig; do
  printf 'signed repository %s\n' "$suffix" > "$artifacts/repositories/core/devario-core.$suffix"
done
ln -s devario-core.db.tar.zst "$artifacts/repositories/core/devario-core.db"
ln -s devario-core.files.tar.zst "$artifacts/repositories/core/devario-core.files"
ln -s devario-core.db.tar.zst.sig "$artifacts/repositories/core/devario-core.db.sig"
ln -s devario-core.files.tar.zst.sig "$artifacts/repositories/core/devario-core.files.sig"
cp -a "$artifacts/." "$builder_output/"
create_build_evidence_fixture "$root" "$builder_output" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1786579200 one
jq -cS -n '[{name:"devario-base",version:"1-1",architecture:"any",packageBase:"devario-base",licenses:["GPL-3.0-or-later"],packager:"ZoeyErinBauer"}]' > "$root/IMAGE-PACKAGE-INVENTORY.json"
package_sha="$(sha256sum "$artifacts/devario-base-1-1-any.pkg.tar.zst" | cut -d' ' -f1)"; package_size="$(stat -c '%s' "$artifacts/devario-base-1-1-any.pkg.tar.zst")"
jq -cS -n --arg binarySha "$package_sha" --argjson binarySize "$package_size" '{"$schema":"./source-index.schema.json",schemaVersion:1,packages:[{name:"devario-base",version:"1-1",architecture:"any",packageBase:"devario-base",binary:{path:"devario-base-1-1-any.pkg.tar.zst",sha256:$binarySha,size:$binarySize},sources:[{uri:"https://github.com/Seafoam-Labs/devario-os",revision:("a"*40),sha256:("1"*64),correspondingSource:true}]}]}' > "$root/source-index.json"
SOURCE_DATE_EPOCH=1786579200 DEVARIO_BUILDER_ID=https://builder.devario.example/controlled \
DEVARIO_INVOCATION_ID=candidate-test-build-one "$project_dir/release/generate-release-metadata.sh" \
  --artifacts "$artifacts" --output "$metadata" --edition community --version test --architecture x86_64 \
  --channel devario-core-testing --core-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --installed-packages "$root/IMAGE-PACKAGE-INVENTORY.json" --source-index "$root/source-index.json" >/dev/null
SOURCE_DATE_EPOCH=1786579200 "$project_dir/release/generate-candidate-lock.sh" --artifacts "$artifacts" --metadata "$metadata" \
  --output "$root/CANDIDATE.json" --edition community --version test --architecture x86_64 --channel devario-core-testing \
  --core-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --core-input-lock "$builder_output/CORE-INPUT-LOCK.json" \
  --builder-manifest "$builder_output/CONTROLLED-BUILDER.json" --builder-manifest-signature "$builder_output/CONTROLLED-BUILDER.json.sig" \
  --builder-attestation "$builder_output/BUILDER-ATTESTATION.json" --builder-attestation-signature "$builder_output/BUILDER-ATTESTATION.json.sig" --builder-output-tree "$builder_output" >/dev/null
"$project_dir/release/validate-candidate-lock.sh" --candidate "$root/CANDIDATE.json" --artifacts "$artifacts" --metadata "$metadata" \
  --core-input-lock "$builder_output/CORE-INPUT-LOCK.json" --builder-manifest "$builder_output/CONTROLLED-BUILDER.json" --builder-manifest-signature "$builder_output/CONTROLLED-BUILDER.json.sig" \
  --builder-attestation "$builder_output/BUILDER-ATTESTATION.json" --builder-attestation-signature "$builder_output/BUILDER-ATTESTATION.json.sig" --builder-output-tree "$builder_output" --allow-pending >/dev/null

printf '{"schemaVersion":1,"placeholder":true}\n' > "$root/placeholder.json"
if SOURCE_DATE_EPOCH=1786579200 "$project_dir/release/generate-candidate-lock.sh" --artifacts "$artifacts" --metadata "$metadata" --output "$root/placeholder-candidate.json" --edition community --version test --architecture x86_64 --channel devario-core-testing --core-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --core-input-lock "$root/placeholder.json" --builder-manifest "$builder_output/CONTROLLED-BUILDER.json" --builder-manifest-signature "$builder_output/CONTROLLED-BUILDER.json.sig" --builder-attestation "$builder_output/BUILDER-ATTESTATION.json" --builder-attestation-signature "$builder_output/BUILDER-ATTESTATION.json.sig" --builder-output-tree "$builder_output" >/dev/null 2>&1; then
  echo 'Candidate generator accepted placeholder input-lock JSON.' >&2; exit 1
fi
if "$project_dir/release/validate-build-evidence.sh" --input-lock "$builder_output/CORE-INPUT-LOCK.json" \
  --builder-manifest "$builder_output/CONTROLLED-BUILDER.json" --builder-manifest-signature "$builder_output/CONTROLLED-BUILDER.json.sig" \
  --attestation "$builder_output/BUILDER-ATTESTATION.json" --attestation-signature "$builder_output/BUILDER-ATTESTATION.json.sig" \
  --output-tree "$builder_output" --edition community --release-version wrong-version --architecture x86_64 \
  --core-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --source-date-epoch 1786579200 --allow-pending >/dev/null 2>&1; then
  echo 'Build evidence accepted a candidate version different from the controlled ISO identity.' >&2; exit 1
fi

chmod 0644 "$artifacts/devario-test.iso"; printf 'tampered\n' >> "$artifacts/devario-test.iso"
if "$project_dir/release/validate-candidate-lock.sh" --candidate "$root/CANDIDATE.json" --artifacts "$artifacts" --metadata "$metadata" \
  --core-input-lock "$builder_output/CORE-INPUT-LOCK.json" --builder-manifest "$builder_output/CONTROLLED-BUILDER.json" --builder-manifest-signature "$builder_output/CONTROLLED-BUILDER.json.sig" \
  --builder-attestation "$builder_output/BUILDER-ATTESTATION.json" --builder-attestation-signature "$builder_output/BUILDER-ATTESTATION.json.sig" --builder-output-tree "$builder_output" --allow-pending >/dev/null 2>&1; then
  echo 'Candidate validator accepted a changed artifact tree.' >&2; exit 1
fi
echo 'Candidate-lock tests passed.'
