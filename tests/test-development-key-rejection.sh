#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
test_root="$(mktemp -d /tmp/devario-development-key.XXXXXX)"
cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT
fail() { echo "Development-key rejection test failed: $*" >&2; exit 1; }
mkdir -p "$test_root/bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'for value in "$@"; do [[ "$value" == --list-packets ]] && exit 0; done' \
  'printf "pub:u:::::::::\\nfpr:::::::::%s:\\nuid:u::::::::Development Key <packages@example.test>:\\n" "$MOCK_PUBLIC_FINGERPRINT"' \
  > "$test_root/bin/gpg"
chmod 0755 "$test_root/bin/gpg"

# shellcheck source=../scripts/lib/repository.sh
source "$project_dir/scripts/lib/repository.sh"
for contract in \
  "devario-core:$DEVARIO_DEVELOPMENT_FINGERPRINT:devario.gpg:devario-trusted:devario-revoked" \
  "devario-managed:$DEVARIO_MANAGED_DEVELOPMENT_FINGERPRINT:devario-managed.gpg:devario-managed-trusted:devario-managed-revoked"; do
  IFS=: read -r repository fingerprint public trusted revoked <<< "$contract"
  bundle="$test_root/$repository"; mkdir -p "$bundle"
  printf '%s\n' public > "$bundle/$public"
  printf '%s:4:\n' "$fingerprint" > "$bundle/$trusted"
  : > "$bundle/$revoked"
  printf '%s\n' "$fingerprint" > "$bundle/active-signer"
  export MOCK_PUBLIC_FINGERPRINT="$fingerprint"
  if PATH="$test_root/bin:$PATH" devario_validate_keyring_bundle \
      "$bundle" "$repository" production >"$test_root/stdout" 2>"$test_root/stderr"; then
    fail "$repository development fingerprint was accepted for production"
  fi
  grep -Fq "$fingerprint" "$test_root/stderr" \
    || fail "$repository rejection did not identify the forbidden fingerprint"
done

echo 'Known development-key rejection tests passed.'
