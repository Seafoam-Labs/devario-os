#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
keyring_dir="$project_dir/packages/devario-keyring"
signing_home="${DEVARIO_GNUPGHOME:-$project_dir/.devario-signing}"
fingerprint_file="$signing_home/fingerprint"
requested_key="${DEVARIO_SIGNING_KEY:-}"

if ! command -v gpg >/dev/null 2>&1; then
  echo "Missing required command: gpg" >&2
  exit 1
fi

mkdir -p "$signing_home" "$keyring_dir"
chmod 700 "$signing_home"

if [[ -z "$requested_key" && -s "$fingerprint_file" ]]; then
  read -r requested_key < "$fingerprint_file"
fi

if [[ -z "$requested_key" ]]; then
  batch_file="$(mktemp /tmp/devario-gpg.XXXXXX)"
  cleanup() {
    rm -f -- "$batch_file"
  }
  trap cleanup EXIT

  printf '%s\n' \
    '%no-protection' \
    'Key-Type: eddsa' \
    'Key-Curve: ed25519' \
    'Key-Usage: sign' \
    'Name-Real: Devario Development Repository' \
    'Name-Email: packages@devario.invalid' \
    'Expire-Date: 1y' \
    '%commit' > "$batch_file"
  GNUPGHOME="$signing_home" gpg --batch --generate-key "$batch_file"
  requested_key="$(
    GNUPGHOME="$signing_home" gpg --batch --with-colons --list-secret-keys \
      | awk -F: '$1 == "fpr" { print $10; exit }'
  )"
fi

if [[ -z "$requested_key" ]]; then
  echo "Could not determine the repository signing-key fingerprint." >&2
  exit 1
fi

fingerprint="$(
  GNUPGHOME="$signing_home" gpg --batch --with-colons \
    --list-secret-keys "$requested_key" \
    | awk -F: '$1 == "fpr" { print $10; exit }'
)"
if [[ -z "$fingerprint" ]]; then
  echo "No secret signing key matching $requested_key exists in $signing_home." >&2
  exit 1
fi

GNUPGHOME="$signing_home" gpg --batch --export "$fingerprint" \
  > "$keyring_dir/devario.gpg"
printf '%s:4:\n' "$fingerprint" > "$keyring_dir/devario-trusted"
: > "$keyring_dir/devario-revoked"
printf '%s\n' "$fingerprint" > "$fingerprint_file"
chmod 600 "$fingerprint_file"

echo "Exported Devario public repository key $fingerprint"
echo "Signing key home: $signing_home"
echo "Use this development key only for local images; use an offline key for releases."
