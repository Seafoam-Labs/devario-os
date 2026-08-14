#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
test_root="$(mktemp -d /tmp/devario-active-signer.XXXXXX)"
cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT
fail() { echo "Active-signer test failed: $*" >&2; exit 1; }

active='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
retired='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
signing='CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC'
mkdir -p "$test_root/bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "[GNUPG:] VALIDSIG %s 2026-08-14 1786665600 0 4 0 22 8 00 %s\\n" "$MOCK_SIGNING_FINGERPRINT" "$MOCK_PRIMARY_FINGERPRINT"' \
  > "$test_root/bin/gpgv"
chmod 0755 "$test_root/bin/gpgv"
printf '%s\n' artifact > "$test_root/artifact"
printf '%s\n' signature > "$test_root/artifact.sig"

# shellcheck source=../scripts/lib/repository.sh
source "$project_dir/scripts/lib/repository.sh"
DEVARIO_KEYRING_PUBLIC="$test_root/public.gpg"
DEVARIO_ACTIVE_SIGNER="$active"
: > "$DEVARIO_KEYRING_PUBLIC"
export MOCK_SIGNING_FINGERPRINT="$signing" MOCK_PRIMARY_FINGERPRINT="$active"
PATH="$test_root/bin:$PATH" devario_gpgv_active_signature \
  "$test_root/artifact.sig" "$test_root/artifact"

export MOCK_PRIMARY_FINGERPRINT="$retired"
if PATH="$test_root/bin:$PATH" devario_gpgv_active_signature \
    "$test_root/artifact.sig" "$test_root/artifact" \
    >"$test_root/stdout" 2>"$test_root/stderr"; then
  fail 'a trusted rotation key was accepted as the active signer'
fi
grep -Fq 'not signed by active-signer' "$test_root/stderr" \
  || fail 'retired-signer rejection did not identify the active-signer mismatch'

echo 'Active-signer trust tests passed.'
