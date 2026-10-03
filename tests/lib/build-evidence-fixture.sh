#!/usr/bin/env bash
# Test-only deterministic structural fixtures; signatures are intentionally not
# production-valid and can be used only with --allow-pending.

create_build_evidence_fixture() {
  local fixture_root="$1" output_tree="$2" core_commit="$3" epoch="$4" run_id="${5:-fixture}" release_version="${6:-test}"
  local manifest="$output_tree/CONTROLLED-BUILDER.json"
  local manifest_signature="$manifest.sig"
  local lock="$output_tree/CORE-INPUT-LOCK.json"
  local attestation="$output_tree/BUILDER-ATTESTATION.json"
  local packages="$fixture_root/builder-packages"
  jq -cS -n '[{name:"base",version:"1-1",architecture:"x86_64"}]' > "$packages"
  dependency_sha="$(sha256sum "$packages" | cut -d' ' -f1)"
  printf 'test controlled-builder signature\n' > "$manifest_signature"
  jq -cS -n --arg dependency "$dependency_sha" '{schemaVersion:2,isoBuilder:{repository:"https://github.com/Seafoam-Labs/devario-iso-builder",revision:("e"*40),sha256:("f"*64)},architecture:"x86_64",rootTreeSha256:("1"*64),repositorySnapshot:{url:"https://repo.seafoam-labs.org/snapshots/2026-08-13/",databases:[{repository:"devario-core",sha256:("2"*64),signatureSha256:("3"*64)}]},bootstrap:{url:"https://archive.archlinux.org/bootstrap.tar.zst",sha256:("6"*64),size:1,signatureSha256:("7"*64)},shellyBootstrap:{sha256:("8"*64),size:1,signatureSha256:("9"*64)},dependencyClosureSha256:$dependency}' > "$manifest"
  manifest_sha="$(sha256sum "$manifest" | cut -d' ' -f1)"; manifest_sig_sha="$(sha256sum "$manifest_signature" | cut -d' ' -f1)"
  source_manifest_sha="$(sha256sum "$project_dir/release/source-manifest.json" | cut -d' ' -f1)"
  jq -cS -n --arg commit "$core_commit" --arg releaseVersion "$release_version" --argjson epoch "$epoch" --arg sourceManifest "$source_manifest_sha" --arg manifest "$manifest_sha" --arg manifestSignature "$manifest_sig_sha" --slurpfile builder "$manifest" '{schemaVersion:2,isoBuilder:$builder[0].isoBuilder,operation:"iso",architecture:"x86_64",releaseVersion:$releaseVersion,core:{schemaVersion:1,commit:$commit,tree:("b"*40),treeListingSha256:("b"*64),sourceDateEpoch:$epoch,archiveSha256:("c"*64)},edition:{id:"community",commit:$commit,tree:("b"*40),path:"editions/community"},sourceManifest:{path:"release/source-manifest.json",sha256:$sourceManifest},sourceDateEpoch:$epoch,controlledBuilder:{manifestSha256:$manifest,manifestSignatureSha256:$manifestSignature,rootTreeSha256:$builder[0].rootTreeSha256,dependencyClosureSha256:$builder[0].dependencyClosureSha256,dependencyClosure:[{name:"base",version:"1-1",architecture:"x86_64"}]},repositorySnapshot:$builder[0].repositorySnapshot,bootstrap:$builder[0].bootstrap,shellyBootstrap:$builder[0].shellyBootstrap,repositories:[{name:"devario-core",files:[{path:"devario-core.db.tar.zst",mode:"100644",size:1,sha256:("a"*64)}]}],keyrings:[{name:"devario-core",files:[{path:"devario.gpg",mode:"100644",size:1,sha256:("d"*64)}]}]}' > "$lock"
  python3 "$project_dir/scripts/write-builder-attestation.py" --input-lock "$lock" --output-tree "$output_tree" --builder-marker "$manifest" --builder-packages "$packages" --operation iso --output "$attestation"
  printf 'test attestation signature %s\n' "$run_id" > "$attestation.sig"
}
