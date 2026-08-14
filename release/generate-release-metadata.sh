#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
source_manifest="$script_dir/source-manifest.json"
# shellcheck source=lib-release.sh
source "$script_dir/lib-release.sh"

usage() {
  cat <<'EOF'
Usage: generate-release-metadata.sh \
  --artifacts DIR --output DIR --edition EDITION --version VERSION \
  --architecture ARCH --channel CHANNEL --core-commit COMMIT \
  --installed-packages IMAGE-PACKAGE-INVENTORY.json \
  --source-index SOURCE-INDEX.json [--overlay-commit COMMIT]

Generate unsigned release checksums, an SPDX 2.3 artifact SBOM, an in-toto
Statement v1/SLSA provenance document, and a release record. The output
directory must not be inside the artifact directory.

The following optional environment variables describe the controlled build:
  SOURCE_DATE_EPOCH          timestamp used for deterministic metadata
  DEVARIO_BUILDER_ID         required URI identifying the controlled builder
  DEVARIO_INVOCATION_ID      required unique build invocation identifier
The SPDX creator is fixed to Person: ZoeyErinBauer. It cannot be overridden by
the build environment.
EOF
}

artifacts_dir=''
output_dir=''
edition=''
version=''
architecture=''
channel=''
core_commit=''
overlay_commit=''
installed_packages=''
source_index=''

while (( $# )); do
  case "$1" in
    --artifacts|--output|--edition|--version|--architecture|--channel|--core-commit|--overlay-commit|--installed-packages|--source-index)
      if (( $# < 2 )); then
        echo "Missing value for $1" >&2
        usage >&2
        exit 2
      fi
      option="$1"
      value="$2"
      shift 2
      case "$option" in
        --artifacts) artifacts_dir="$value" ;;
        --output) output_dir="$value" ;;
        --edition) edition="$value" ;;
        --version) version="$value" ;;
        --architecture) architecture="$value" ;;
        --channel) channel="$value" ;;
        --core-commit) core_commit="$value" ;;
        --overlay-commit) overlay_commit="$value" ;;
        --installed-packages) installed_packages="$value" ;;
        --source-index) source_index="$value" ;;
      esac
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for required_value in artifacts_dir output_dir edition version architecture channel core_commit installed_packages source_index; do
  if [[ -z "${!required_value}" ]]; then
    echo "Missing required option for ${required_value//_/-}." >&2
    usage >&2
    exit 2
  fi
done
devario_validate_release_version "$version" || {
  echo 'Version must match the canonical 1-64 character release-version pattern.' >&2
  exit 1
}

for command_name in date find grep install jq mktemp python3 realpath sha256sum sort stat; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

if [[ ! -d "$artifacts_dir" ]]; then
  echo "Artifact directory does not exist: $artifacts_dir" >&2
  exit 1
fi
if [[ ! -r "$source_manifest" ]]; then
  echo "Vendored-source manifest is missing: $source_manifest" >&2
  exit 1
fi
for release_input in "$installed_packages" "$source_index"; do
  [[ -f "$release_input" && ! -L "$release_input" ]] || { echo "Release evidence is missing or unsafe: $release_input" >&2; exit 1; }
done
python3 "$script_dir/validate-json.py" "$script_dir/installed-package-inventory.schema.json" "$installed_packages"
python3 "$script_dir/validate-json.py" "$script_dir/source-index.schema.json" "$source_index"
inventory_canonical="$(mktemp /tmp/devario-inventory-canonical.XXXXXX)"
source_index_canonical="$(mktemp /tmp/devario-source-index-canonical.XXXXXX)"
jq -cS '.' "$installed_packages" > "$inventory_canonical"; jq -cS '.' "$source_index" > "$source_index_canonical"
cmp -s "$inventory_canonical" "$installed_packages" || { rm -f -- "$inventory_canonical" "$source_index_canonical"; echo 'Installed package inventory must be canonical JSON.' >&2; exit 1; }
cmp -s "$source_index_canonical" "$source_index" || { rm -f -- "$inventory_canonical" "$source_index_canonical"; echo 'Source index must be canonical JSON.' >&2; exit 1; }
rm -f -- "$inventory_canonical" "$source_index_canonical"
if ! jq -e --slurpfile inventory "$installed_packages" '
  ([.packages[] | [.name,.version,.architecture,.packageBase]] | sort) ==
  ([$inventory[0][] | [.name,.version,.architecture,.packageBase]] | sort) and
  ([.packages[].name] | length) == ([.packages[].name] | unique | length)
' "$source_index" >/dev/null; then
  echo 'Source index does not map every exact installed package once.' >&2; exit 1
fi
if ! python3 "$script_dir/validate-json.py" \
  "$script_dir/source-manifest.schema.json" "$source_manifest"; then
  echo "Vendored-source manifest failed its Draft 2020-12 schema." >&2
  exit 1
fi

artifacts_dir="$(realpath -- "$artifacts_dir")"
output_dir="$(realpath -m -- "$output_dir")"
devario_validate_source_binary_closure "$source_index" "$artifacts_dir"
case "$output_dir/" in
  "$artifacts_dir/"*)
    echo "Output directory must not be inside the artifact directory." >&2
    exit 1
    ;;
esac
if [[ -e "$output_dir" && ! -d "$output_dir" ]]; then
  echo "Output path exists and is not a directory: $output_dir" >&2
  exit 1
fi
if [[ -d "$output_dir" ]] \
  && find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  echo "Output directory must be empty: $output_dir" >&2
  exit 1
fi

safe_token='^[A-Za-z0-9][A-Za-z0-9._-]*$'
for token_name in edition version architecture channel; do
  if [[ ! "${!token_name}" =~ $safe_token ]]; then
    echo "$token_name contains an unsupported character: ${!token_name}" >&2
    exit 1
  fi
done
if [[ ! "$core_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "--core-commit must be a full lowercase 40-character Git object ID." >&2
  exit 1
fi
if [[ -n "$overlay_commit" && ! "$overlay_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "--overlay-commit must be a full lowercase 40-character Git object ID." >&2
  exit 1
fi
if [[ "$edition" == managed && -z "$overlay_commit" ]]; then
  echo "Managed metadata requires --overlay-commit." >&2
  exit 1
fi
if [[ "$edition" != managed && -n "$overlay_commit" ]]; then
  echo "--overlay-commit is valid only for the managed edition." >&2
  exit 1
fi

if [[ ! "${SOURCE_DATE_EPOCH:-}" =~ ^[1-9][0-9]*$ ]]; then
  echo "SOURCE_DATE_EPOCH must be set to a positive integer for release metadata." >&2
  exit 1
fi
generated_at="$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"

builder_id="${DEVARIO_BUILDER_ID:-}"
invocation_id="${DEVARIO_INVOCATION_ID:-}"
[[ "$builder_id" =~ ^https://[^[:space:]]+$ ]] || { echo 'DEVARIO_BUILDER_ID must be an explicit HTTPS controlled-builder URI.' >&2; exit 1; }
[[ "$invocation_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{7,255}$ ]] || { echo 'DEVARIO_INVOCATION_ID must be an explicit unique identifier.' >&2; exit 1; }
metadata_creator='Person: ZoeyErinBauer'

temp_dir="$(mktemp -d /tmp/devario-release-metadata.XXXXXX)"
cleanup() {
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT

# Refuse a stale or incomplete checked-in vendored-source inventory before
# describing release output. Paths are constrained to the repository root.
if ! jq -e '
  .schemaVersion == 1 and
  (.repository | type == "string") and
  (.sourceRevision | test("^[0-9a-f]{40}$")) and
  (.importedFrom.repository | type == "string") and
  (.importedFrom.revision | test("^[0-9a-f]{40}$")) and
  (.artifacts | length) > 0 and
  all(.artifacts[];
    (.id | type == "string") and
    (.path | type == "string") and
    (.size | type == "number") and
    (.sha256 | test("^[0-9a-f]{64}$")) and
    (.upstream.url | type == "string") and
    (.upstream.revision | type == "string") and
    (.declaredLicenses | length) > 0 and
    .correspondingSource == true
  )
' "$source_manifest" >/dev/null; then
  echo "Vendored-source manifest has invalid or incomplete metadata." >&2
  exit 1
fi
while IFS=$'\t' read -r source_path expected_digest expected_size; do
  case "$source_path" in
    /*|../*|*/../*|*/..)
      echo "Unsafe path in source manifest: $source_path" >&2
      exit 1
      ;;
  esac
  full_source_path="$project_dir/$source_path"
  if [[ ! -f "$full_source_path" ]]; then
    echo "Vendored source is missing: $source_path" >&2
    exit 1
  fi
  actual_digest="$(sha256sum -- "$full_source_path")"
  actual_digest="${actual_digest%% *}"
  actual_size="$(stat -c '%s' -- "$full_source_path")"
  if [[ "$actual_digest" != "$expected_digest" || "$actual_size" != "$expected_size" ]]; then
    echo "Vendored source does not match its manifest: $source_path" >&2
    exit 1
  fi
done < <(jq -r '.artifacts[] | [.path, .sha256, (.size | tostring)] | @tsv' "$source_manifest")

devario_require_closed_tree "$artifacts_dir"

mapfile -d '' artifact_paths < <(
  find "$artifacts_dir" -type f -printf '%P\0' | sort -z
)
if (( ${#artifact_paths[@]} == 0 )); then
  echo "Artifact directory contains no files: $artifacts_dir" >&2
  exit 1
fi

: > "$temp_dir/SHA256SUMS"
: > "$temp_dir/subjects.jsonl"
: > "$temp_dir/spdx-files.jsonl"

artifact_index=0
for artifact_name in "${artifact_paths[@]}"; do
  if [[ "$artifact_name" == *$'\n'* || "$artifact_name" == *$'\r'* ]]; then
    echo "Artifact names may not contain a newline: $artifact_name" >&2
    exit 1
  fi
  artifact_path="$artifacts_dir/$artifact_name"
  artifact_digest="$(sha256sum -- "$artifact_path")"
  artifact_digest="${artifact_digest%% *}"
  artifact_size="$(stat -c '%s' -- "$artifact_path")"
  printf '%s  %s\n' "$artifact_digest" "$artifact_name" >> "$temp_dir/SHA256SUMS"

  jq -cn \
    --arg name "$artifact_name" \
    --arg sha256 "$artifact_digest" \
    --argjson size "$artifact_size" \
    '{name: $name, digest: {sha256: $sha256}, size: $size}' \
    >> "$temp_dir/subjects.jsonl"

  artifact_index=$((artifact_index + 1))
  jq -cn \
    --arg id "SPDXRef-Artifact-$artifact_index" \
    --arg name "./$artifact_name" \
    --arg sha256 "$artifact_digest" \
    --argjson size "$artifact_size" \
    '{
      fileName: $name,
      SPDXID: $id,
      checksums: [{algorithm: "SHA256", checksumValue: $sha256}],
      licenseConcluded: "NOASSERTION",
      copyrightText: "NOASSERTION",
      comment: ("Release artifact size: " + ($size | tostring) + " bytes")
    }' >> "$temp_dir/spdx-files.jsonl"
done

jq -s '.' "$temp_dir/subjects.jsonl" > "$temp_dir/subjects.json"
jq -s '.' "$temp_dir/spdx-files.jsonl" > "$temp_dir/spdx-files.json"
subject_set_digest="$(sha256sum -- "$temp_dir/SHA256SUMS")"
subject_set_digest="${subject_set_digest%% *}"
source_manifest_digest="$(sha256sum -- "$source_manifest")"
source_manifest_digest="${source_manifest_digest%% *}"
installed_packages_digest="$(sha256sum -- "$installed_packages")"; installed_packages_digest="${installed_packages_digest%% *}"
source_index_digest="$(sha256sum -- "$source_index")"; source_index_digest="${source_index_digest%% *}"

overlay_json='null'
if [[ -n "$overlay_commit" ]]; then
  overlay_json="$(jq -cn --arg commit "$overlay_commit" '$commit')"
fi

jq -n \
  --arg edition "$edition" \
  --arg version "$version" \
  --arg architecture "$architecture" \
  --arg channel "$channel" \
  --arg coreCommit "$core_commit" \
  --arg generatedAt "$generated_at" \
  --arg sourceDateEpoch "$SOURCE_DATE_EPOCH" \
  --arg sourceDigest "$source_manifest_digest" \
  --arg builderId "$builder_id" \
  --arg invocationId "$invocation_id" \
  --arg inventoryDigest "$installed_packages_digest" \
  --arg sourceIndexDigest "$source_index_digest" \
  --argjson overlayCommit "$overlay_json" \
  --slurpfile subjects "$temp_dir/subjects.json" \
  '{
    schemaVersion: 2,
    edition: $edition,
    version: $version,
    architecture: $architecture,
    channel: $channel,
    generatedAt: $generatedAt,
    sourceDateEpoch: ($sourceDateEpoch | tonumber),
    build: {builderId: $builderId, invocationId: $invocationId},
    imagePackageInventory: {path:"IMAGE-PACKAGE-INVENTORY.json",sha256:$inventoryDigest},
    correspondingSourceIndex: {path:"source-index.json",sha256:$sourceIndexDigest},
    source: {
      coreCommit: $coreCommit,
      overlayCommit: $overlayCommit,
      vendoredSourceManifest: {
        path: "release/source-manifest.json",
        sha256: $sourceDigest
      }
    },
    subjects: $subjects[0]
  }' > "$temp_dir/release.json"

if ! python3 "$script_dir/validate-json.py" \
  "$script_dir/release-metadata.schema.json" "$temp_dir/release.json"; then
  echo "Generated release metadata failed its schema." >&2
  exit 1
fi

jq -n \
  --arg name "Devario-$edition-$version-$architecture" \
  --arg namespace "https://github.com/Seafoam-Labs/devario-os/releases/$version/spdx-$subject_set_digest" \
  --arg created "$generated_at" \
  --arg creator "$metadata_creator" \
  --slurpfile files "$temp_dir/spdx-files.json" \
  '{
    spdxVersion: "SPDX-2.3",
    dataLicense: "CC0-1.0",
    SPDXID: "SPDXRef-DOCUMENT",
    name: $name,
    documentNamespace: $namespace,
    creationInfo: {
      created: $created,
      creators: [$creator, "Tool: devario-release-metadata"]
    },
    documentDescribes: ($files[0] | map(.SPDXID)),
    files: $files[0]
  }' > "$temp_dir/release.spdx.json"

jq -n --arg name "Devario-$edition-$version-$architecture-installed-packages" \
  --arg namespace "https://github.com/Seafoam-Labs/devario-os/releases/$version/installed-$installed_packages_digest" \
  --arg created "$generated_at" --arg creator "$metadata_creator" \
  --slurpfile inventory "$installed_packages" --slurpfile sources "$source_index" '
  {
    spdxVersion:"SPDX-2.3",dataLicense:"CC0-1.0",SPDXID:"SPDXRef-DOCUMENT",name:$name,
    documentNamespace:$namespace,creationInfo:{created:$created,creators:[$creator,"Tool: devario-release-metadata"]},
    documentDescribes:[$inventory[0][] | "SPDXRef-Package-" + (.name|gsub("[^A-Za-z0-9.-]";"-"))],
    packages:[$inventory[0][] as $package |
      ($sources[0].packages[] | select(.name==$package.name)) as $source |
      {name:$package.name,SPDXID:("SPDXRef-Package-"+($package.name|gsub("[^A-Za-z0-9.-]";"-"))),versionInfo:$package.version,
       supplier:(if $package.packager=="" then "NOASSERTION" else "Organization: "+$package.packager end),
       downloadLocation:"NOASSERTION",filesAnalyzed:false,
       licenseDeclared:(if ($package.licenses|length)==0 then "NOASSERTION" else ($package.licenses|join(" AND ")) end),
       licenseConcluded:"NOASSERTION",copyrightText:"NOASSERTION",
       comment:("architecture="+$package.architecture+"; packageBase="+$package.packageBase+"; binary="+$source.binary.path+"@"+$source.binary.sha256+"; correspondingSource="+([$source.sources[].uri]|join(",")))}]
  }' > "$temp_dir/installed-packages.spdx.json"

jq -n \
  --arg builderId "$builder_id" \
  --arg invocationId "$invocation_id" \
  --arg generatedAt "$generated_at" \
  --arg edition "$edition" \
  --arg version "$version" \
  --arg architecture "$architecture" \
  --arg channel "$channel" \
  --arg coreCommit "$core_commit" \
  --argjson overlayCommit "$overlay_json" \
  --arg sourceDigest "$source_manifest_digest" \
  --slurpfile subjects "$temp_dir/subjects.json" \
  '{
    "_type": "https://in-toto.io/Statement/v1",
    subject: $subjects[0],
    predicateType: "https://slsa.dev/provenance/v1",
    predicate: {
      buildDefinition: {
        buildType: "https://github.com/Seafoam-Labs/devario-os/blob/main/docs/RELEASE-POLICY.md",
        externalParameters: {
          edition: $edition,
          version: $version,
          architecture: $architecture,
          channel: $channel,
          coreCommit: $coreCommit,
          overlayCommit: $overlayCommit
        },
        internalParameters: {},
        resolvedDependencies: ([{
          uri: "git+https://github.com/Seafoam-Labs/devario-os.git",
          digest: {gitCommit: $coreCommit}
        }] + (if $overlayCommit == null then [] else [{
          uri: "git+https://github.com/Seafoam-Labs/devario-managed-overlay.git",
          digest: {gitCommit: $overlayCommit}
        }] end))
      },
      runDetails: {
        builder: {id: $builderId},
        metadata: {
          invocationId: $invocationId,
          startedOn: $generatedAt,
          finishedOn: $generatedAt
        },
        byproducts: [{
          name: "release/source-manifest.json",
          digest: {sha256: $sourceDigest}
        }]
      }
    }
  }' > "$temp_dir/provenance.intoto.json"

mkdir -p -- "$output_dir"
install -m 0644 "$temp_dir/SHA256SUMS" "$output_dir/SHA256SUMS"
install -m 0644 "$temp_dir/release.json" "$output_dir/release.json"
install -m 0644 "$temp_dir/release.spdx.json" "$output_dir/release.spdx.json"
install -m 0644 "$temp_dir/provenance.intoto.json" "$output_dir/provenance.intoto.json"
install -m 0644 "$source_manifest" "$output_dir/source-manifest.json"
install -m 0644 "$installed_packages" "$output_dir/IMAGE-PACKAGE-INVENTORY.json"
install -m 0644 "$source_index" "$output_dir/source-index.json"
install -m 0644 "$temp_dir/installed-packages.spdx.json" "$output_dir/installed-packages.spdx.json"

(
  cd "$output_dir"
  sha256sum -- \
    SHA256SUMS \
    IMAGE-PACKAGE-INVENTORY.json \
    installed-packages.spdx.json \
    provenance.intoto.json \
    release.json \
    release.spdx.json \
    source-manifest.json \
    source-index.json \
    > METADATA.SHA256SUMS
)

echo "Unsigned release metadata is available at $output_dir"
echo "Review it, then sign METADATA.SHA256SUMS through the production release process."
