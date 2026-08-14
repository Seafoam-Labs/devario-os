#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
attestation=''
signature=''
input_lock=''
output_tree=''
keyring_dir=''
repository_name=''
while (( $# )); do
  case "$1" in
    --attestation) attestation="$2"; shift 2 ;;
    --signature) signature="$2"; shift 2 ;;
    --input-lock) input_lock="$2"; shift 2 ;;
    --output-tree) output_tree="$2"; shift 2 ;;
    --keyring-dir) keyring_dir="$2"; shift 2 ;;
    --repository-name) repository_name="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
for value in "$attestation" "$signature" "$input_lock" "$output_tree" "$keyring_dir" "$repository_name"; do
  [[ -n "$value" ]] || { echo 'Builder-attestation verifier is missing a required option.' >&2; exit 2; }
done
[[ -d "$output_tree" && ! -L "$output_tree" ]] || {
  echo 'Builder-attestation output tree must be a real directory.' >&2; exit 1;
}
output_tree="$(realpath -e -- "$output_tree")"
declare -A canonical_evidence=(
  ["$input_lock"]="$output_tree/CORE-INPUT-LOCK.json"
  ["$attestation"]="$output_tree/BUILDER-ATTESTATION.json"
  ["$signature"]="$output_tree/BUILDER-ATTESTATION.json.sig"
)
for supplied in "${!canonical_evidence[@]}"; do
  expected="${canonical_evidence[$supplied]}"
  if [[ ! -f "$supplied" || -L "$supplied" || ! -f "$expected" || -L "$expected" \
    || "$(realpath -e -- "$supplied")" != "$expected" ]]; then
    echo "Builder evidence must use its canonical in-tree path: $expected" >&2
    exit 1
  fi
done
# shellcheck source=lib/repository.sh
source "$script_dir/lib/repository.sh"
devario_validate_keyring_bundle "$keyring_dir" "$repository_name" production
devario_gpgv_active_signature "$signature" "$attestation"
devario_gpgv_active_signature "$output_tree/CONTROLLED-BUILDER.json.sig" \
  "$output_tree/CONTROLLED-BUILDER.json"
python3 "$script_dir/verify-builder-attestation.py" \
  --attestation "$attestation" --input-lock "$input_lock" --output-tree "$output_tree"
