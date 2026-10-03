#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"; root="$(mktemp -d /tmp/devario-boot-harness-test.XXXXXX)"; trap 'rm -rf -- "$root"' EXIT
mkdir "$root/bin" "$root/out"; printf 'candidate iso bytes\n' > "$root/devario.iso"; printf 'installed disk bytes\n' > "$root/installed.raw"
iso_sha="$(sha256sum "$root/devario.iso" | cut -d' ' -f1)"; iso_size="$(stat -c '%s' "$root/devario.iso")"; iso_mode="$(stat -c '%a' "$root/devario.iso")"
jq -n --arg sha "$iso_sha" --argjson size "$iso_size" --arg mode "$iso_mode" '
{schemaVersion:2,edition:"community",version:"test",architecture:"x86_64",candidateChannel:"devario-core-testing",
 coreCommit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",overlayCommit:null,sourceDateEpoch:1786579200,createdAt:"2026-08-13T00:00:00Z",
 artifacts:[{path:"devario.iso",sha256:$sha,size:$size,mode:$mode}],artifactSetSha256:("a"*64),
 metadata:[{path:"release.json",sha256:("b"*64),size:1,mode:"644"}],metadataSetSha256:("c"*64),
 buildEvidence:{coreInputLock:{name:"CORE-INPUT-LOCK.json",sha256:("d"*64)},overlayInputLock:null,builderManifest:{name:"CONTROLLED-BUILDER.json",sha256:("1"*64)},builderManifestSignature:{name:"CONTROLLED-BUILDER.json.sig",sha256:("2"*64)},builderAttestation:{name:"BUILDER-ATTESTATION.json",sha256:("e"*64)},builderAttestationSignature:{name:"BUILDER-ATTESTATION.json.sig",sha256:("3"*64)}}}' > "$root/candidate.json"
"$project_dir/release/validate-json.py" "$project_dir/release/candidate-lock.schema.json" "$root/candidate.json"
printf "UEFI fixture\n" > "$root/OVMF_CODE.fd"
export DEVARIO_OVMF_CODE="$root/OVMF_CODE.fd"
printf '%s\n' '#!/usr/bin/env bash' 'request=' 'for argument in "$@"; do case "$argument" in name=opt/org.devario/acceptance,string=*) request="${argument#*string=}";; esac; done' 'case "${MOCK_MARKER_STYLE:-good}" in good) printf "DEVARIO_ACCEPTANCE:PASS %s\n" "$request";; suffix) printf "DEVARIO_ACCEPTANCE:PASS %s unexpected\n" "$request";; double) printf "DEVARIO_ACCEPTANCE:PASS %s\nDEVARIO_ACCEPTANCE:PASS %s\n" "$request" "$request";; esac' > "$root/bin/qemu-system-x86_64"
chmod 0755 "$root/bin/qemu-system-x86_64"
PATH="$root/bin:$PATH" "$project_dir/scripts/test-image-boot.sh" --image "$root/devario.iso" --candidate "$root/candidate.json" --mode live --firmware bios --edition community --log "$root/out/live.log" --result "$root/out/live.json" --timeout 5 >/dev/null
"$project_dir/release/validate-json.py" "$project_dir/release/image-acceptance.schema.json" "$root/out/live.json"

for style in suffix double; do
  if PATH="$root/bin:$PATH" MOCK_MARKER_STYLE="$style" "$project_dir/scripts/test-image-boot.sh" --image "$root/devario.iso" --candidate "$root/candidate.json" --mode live --firmware bios --edition community --log "$root/out/$style.log" --result "$root/out/$style.json" --timeout 5 >/dev/null 2>&1; then
    echo "Harness accepted $style marker output." >&2; exit 1
  fi
done
printf 'unrelated bytes\n' > "$root/unrelated.iso"
if PATH="$root/bin:$PATH" "$project_dir/scripts/test-image-boot.sh" --image "$root/unrelated.iso" --candidate "$root/candidate.json" --mode live --firmware bios --edition community --log "$root/out/unrelated.log" --result "$root/out/unrelated.json" --timeout 5 >/dev/null 2>&1; then
  echo 'Harness accepted an image outside the candidate.' >&2; exit 1
fi

DEVARIO_INSTALLATION_LOCK_TIME=2026-08-13T00:00:00Z "$project_dir/release/generate-installation-lock.sh" --candidate "$root/candidate.json" --source-image "$root/devario.iso" --disk "$root/installed.raw" --disk-format raw --output "$root/installation-lock.json" >/dev/null
PATH="$root/bin:$PATH" "$project_dir/scripts/test-image-boot.sh" --disk "$root/installed.raw" --disk-format raw --source-image "$root/devario.iso" --installation-lock "$root/installation-lock.json" --candidate "$root/candidate.json" --mode installed --firmware uefi --edition community --log "$root/out/installed.log" --result "$root/out/installed.json" --timeout 5 >/dev/null
if PATH="$root/bin:$PATH" "$project_dir/scripts/test-image-boot.sh" --disk "$root/installed.raw" --candidate "$root/candidate.json" --mode installed --firmware bios --edition community --log "$root/out/bios.log" --result "$root/out/bios.json" >/dev/null 2>&1; then
  echo 'Harness accepted an unsupported installed BIOS boot.' >&2; exit 1
fi
printf 'changed\n' >> "$root/installed.raw"
if PATH="$root/bin:$PATH" "$project_dir/scripts/test-image-boot.sh" --disk "$root/installed.raw" --disk-format raw --source-image "$root/devario.iso" --installation-lock "$root/installation-lock.json" --candidate "$root/candidate.json" --mode installed --firmware uefi --edition community --log "$root/out/changed.log" --result "$root/out/changed.json" --timeout 5 >/dev/null 2>&1; then
  echo 'Harness accepted an installed disk that differed from its lock.' >&2; exit 1
fi
echo 'Image boot harness tests passed.'
