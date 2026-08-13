#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
source_manifest="$script_dir/source-manifest.json"

usage() {
  cat <<'EOF'
Usage: generate-release-metadata.sh \
  --artifacts DIR --output DIR --edition EDITION --version VERSION \
  --architecture ARCH --channel CHANNEL --core-commit COMMIT \
  [--overlay-commit COMMIT]

Generate unsigned release checksums, an SPDX 2.3 artifact SBOM, an in-toto
Statement v1/SLSA provenance document, and a release record. The output
directory must not be inside the artifact directory.

The following optional environment variables describe the controlled build:
  SOURCE_DATE_EPOCH          timestamp used for deterministic metadata
  DEVARIO_BUILDER_ID         URI identifying the builder
  DEVARIO_INVOCATION_ID      unique build invocation identifier
  DEVARIO_METADATA_CREATOR   SPDX creator, default: Person: ZoeyErinBauer
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

while (( $# )); do
  case "$1" in
    --artifacts|--output|--edition|--version|--architecture|--channel|--core-commit|--overlay-commit)
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

for required_value in artifacts_dir output_dir edition version architecture channel core_commit; do
  if [[ -z "${!required_value}" ]]; then
    echo "Missing required option for ${required_value//_/-}." >&2
    usage >&2
    exit 2
  fi
done

for command_name in date find grep install jq mktemp realpath sha256sum sort stat; do
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

artifacts_dir="$(realpath -- "$artifacts_dir")"
output_dir="$(realpath -m -- "$output_dir")"
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

if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
  if [[ ! "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]]; then
    echo "SOURCE_DATE_EPOCH must be a non-negative integer." >&2
    exit 1
  fi
  generated_at="$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"
else
  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi

builder_id="${DEVARIO_BUILDER_ID:-https://github.com/Seafoam-Labs/devario-os}"
invocation_id="${DEVARIO_INVOCATION_ID:-manual-${core_commit:0:12}-${version}}"
metadata_creator="${DEVARIO_METADATA_CREATOR:-Person: ZoeyErinBauer}"

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

mapfile -d '' artifact_paths < <(
  find "$artifacts_dir" -maxdepth 1 -type f -printf '%f\0' | sort -z
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
  --arg sourceDigest "$source_manifest_digest" \
  --argjson overlayCommit "$overlay_json" \
  --slurpfile subjects "$temp_dir/subjects.json" \
  '{
    schemaVersion: 1,
    edition: $edition,
    version: $version,
    architecture: $architecture,
    channel: $channel,
    generatedAt: $generatedAt,
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

(
  cd "$output_dir"
  sha256sum -- \
    SHA256SUMS \
    provenance.intoto.json \
    release.json \
    release.spdx.json \
    source-manifest.json \
    > METADATA.SHA256SUMS
)

echo "Unsigned release metadata is available at $output_dir"
echo "Review it, then sign METADATA.SHA256SUMS through the production release process."
