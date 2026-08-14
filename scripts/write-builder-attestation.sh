#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
keyring_dir=''
repository_name=''
signing_home=''
signing_key=''
output=''
python_args=()
while (( $# )); do
  case "$1" in
    --keyring-dir) keyring_dir="$2"; shift 2 ;;
    --repository-name) repository_name="$2"; shift 2 ;;
    --signing-home) signing_home="$2"; shift 2 ;;
    --signing-key) signing_key="$2"; shift 2 ;;
    --output) output="$2"; python_args+=("$1" "$2"); shift 2 ;;
    *) python_args+=("$1"); shift ;;
  esac
done
if [[ -z "$keyring_dir" || -z "$repository_name" || -z "$signing_home" \
  || -z "$signing_key" || -z "$output" ]]; then
  echo 'Signed attestation requires keyring, repository, signing home/key, and output.' >&2
  exit 2
fi
# shellcheck source=lib/repository.sh
source "$script_dir/lib/repository.sh"
devario_validate_keyring_bundle "$keyring_dir" "$repository_name" production
devario_require_active_secret_signer "$signing_home" "$signing_key"
python3 "$script_dir/write-builder-attestation.py" "${python_args[@]}"
GNUPGHOME="$signing_home" gpg --batch --yes --detach-sign \
  --local-user "$DEVARIO_SIGNING_FINGERPRINT" \
  --output "$output.sig" "$output"
chmod 0444 "$output" "$output.sig"
devario_gpgv_active_signature "$output.sig" "$output"
