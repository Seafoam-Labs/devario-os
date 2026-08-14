#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
# shellcheck source=lib/repository.sh
source "$script_dir/lib/repository.sh"

keyring_dir="${DEVARIO_KEYRING_DIR:-$project_dir/packages/devario-keyring}"
signing_home="${DEVARIO_GNUPGHOME:-$project_dir/.devario-signing}"
requested_key="${DEVARIO_SIGNING_KEY:-}"
policy=development
generate=0
revoke_key=''

usage() {
  cat <<'EOF'
Usage: ./scripts/init-repository-key.sh [options]

Export a rotation-safe core public-key bundle from an external GnuPG home.
Existing public keys remain in the bundle so clients can receive a replacement
before the active signer changes. Secret key packets are never exported.

Options:
  --key FINGERPRINT     Add/trust this primary key and make it active
  --revoke FINGERPRINT  Move a bundled key from trusted to revoked
  --production          Refuse development/.invalid identities; never generate
  --development         Allow a local one-year development key (default)
  --generate            Generate a new development key before exporting
EOF
}

while (( $# )); do
  case "$1" in
    --key)
      (( $# >= 2 )) || { echo '--key requires a fingerprint.' >&2; exit 2; }
      requested_key="$2"
      shift 2
      ;;
    --revoke)
      (( $# >= 2 )) || { echo '--revoke requires a fingerprint.' >&2; exit 2; }
      revoke_key="${2^^}"
      shift 2
      ;;
    --production) policy=production; shift ;;
    --development) policy=development; shift ;;
    --generate) generate=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v gpg >/dev/null 2>&1 || { echo 'Missing required command: gpg' >&2; exit 1; }
if [[ "$policy" == production && "$generate" == 1 ]]; then
  echo 'Production keys must be created by the approved offline process.' >&2
  exit 1
fi
if [[ -n "$revoke_key" && ! "$revoke_key" =~ ^[0-9A-F]{40}([0-9A-F]{24})?$ ]]; then
  echo 'A revoked key must be a full uppercase primary-key fingerprint.' >&2
  exit 2
fi

if [[ "$policy" == production ]]; then
  if [[ -z "${DEVARIO_GNUPGHOME:-}" || "$signing_home" != /* \
    || ! -d "$signing_home" || -L "$signing_home" ]]; then
    echo 'Production export requires an existing absolute external DEVARIO_GNUPGHOME.' >&2
    exit 1
  fi
  signing_home="$(realpath -e -- "$signing_home")"
  if [[ "$(stat -c '%u' "$signing_home")" != "$EUID" \
    || "$(stat -c '%a' "$signing_home")" != 700 ]]; then
    echo 'Production signing home must be owned by the invoking user and mode 0700.' >&2
    exit 1
  fi
  for forbidden_root in "$project_dir" "$keyring_dir"; do
    forbidden_root="$(realpath -m -- "$forbidden_root")"
    if [[ "$signing_home" == "$forbidden_root" \
      || "$signing_home" == "$forbidden_root/"* ]]; then
      echo 'Production signing home must be physically outside source and keyring roots.' >&2
      exit 1
    fi
  done
fi

install -d -m 0700 "$signing_home"
install -d -m 0755 "$keyring_dir"

if (( generate )) || { [[ -z "$requested_key" ]] && [[ ! -s "$keyring_dir/active-signer" ]]; }; then
  batch_file="$(mktemp /tmp/devario-gpg.XXXXXX)"
  cleanup() { rm -f -- "$batch_file"; }
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
  requested_key="$(GNUPGHOME="$signing_home" gpg --batch --with-colons \
    --list-secret-keys | awk -F: '$1 == "fpr" { value=$10 } END { print value }')"
  rm -f -- "$batch_file"
  trap - EXIT
elif [[ -z "$requested_key" ]]; then
  read -r requested_key < "$keyring_dir/active-signer"
fi

fingerprint="$(GNUPGHOME="$signing_home" gpg --batch --with-colons \
  --list-secret-keys "$requested_key" 2>/dev/null \
  | awk -F: '$1 == "fpr" { print $10; exit }')"
if [[ -z "$fingerprint" ]]; then
  echo "No secret signing key matching $requested_key exists in $signing_home." >&2
  exit 1
fi
fingerprint="${fingerprint^^}"

temporary_bundle="$(mktemp /tmp/devario-public-bundle.XXXXXX)"
temporary_trusted="$(mktemp /tmp/devario-trusted.XXXXXX)"
temporary_revoked="$(mktemp /tmp/devario-revoked.XXXXXX)"
cleanup_bundle() { rm -f -- "$temporary_bundle" "$temporary_trusted" "$temporary_revoked"; }
trap cleanup_bundle EXIT

# Preserve every previously classified public key and append the replacement.
if [[ -s "$keyring_dir/devario.gpg" ]]; then
  install -m 0644 "$keyring_dir/devario.gpg" "$temporary_bundle"
fi
if [[ ! -s "$temporary_bundle" ]] \
  || ! gpg --batch --with-colons --import-options show-only --import \
    "$temporary_bundle" 2>/dev/null \
    | awk -F: -v expected="$fingerprint" '$1 == "fpr" && $10 == expected { found=1 } END { exit !found }'; then
  GNUPGHOME="$signing_home" gpg --batch --export "$fingerprint" >> "$temporary_bundle"
fi

declare -A trusted_set=() revoked_set=()
if [[ -f "$keyring_dir/devario-trusted" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^([0-9A-F]{40}([0-9A-F]{24})?):4:$ ]] || continue
    trusted_set["${BASH_REMATCH[1]}"]=1
  done < "$keyring_dir/devario-trusted"
fi
if [[ -f "$keyring_dir/devario-revoked" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^[0-9A-F]{40}([0-9A-F]{24})?$ ]] || continue
    revoked_set["$line"]=1
  done < "$keyring_dir/devario-revoked"
fi
trusted_set["$fingerprint"]=1
unset 'revoked_set[$fingerprint]'
if [[ -n "$revoke_key" ]]; then
  if [[ "$revoke_key" == "$fingerprint" ]]; then
    echo 'The newly selected active signer cannot be revoked.' >&2
    exit 1
  fi
  unset 'trusted_set[$revoke_key]'
  revoked_set["$revoke_key"]=1
fi

printf '%s\n' "${!trusted_set[@]}" | LC_ALL=C sort \
  | sed '/^$/d; s/$/:4:/' > "$temporary_trusted"
printf '%s\n' "${!revoked_set[@]}" | LC_ALL=C sort \
  | sed '/^$/d' > "$temporary_revoked"

install -m 0644 "$temporary_bundle" "$keyring_dir/devario.gpg"
install -m 0644 "$temporary_trusted" "$keyring_dir/devario-trusted"
install -m 0644 "$temporary_revoked" "$keyring_dir/devario-revoked"
printf '%s\n' "$fingerprint" > "$keyring_dir/active-signer"
chmod 0644 "$keyring_dir/active-signer"

devario_validate_keyring_bundle "$keyring_dir" devario-core "$policy"
if [[ "$DEVARIO_ACTIVE_SIGNER" != "$fingerprint" ]]; then
  echo 'The exported bundle did not retain the requested active signer.' >&2
  exit 1
fi

echo "Exported Devario core public-key bundle; active signer: $fingerprint"
echo "Signing key home: $signing_home"
if [[ "$policy" == development ]]; then
  echo 'Development key material must never be used for a public release.'
fi
