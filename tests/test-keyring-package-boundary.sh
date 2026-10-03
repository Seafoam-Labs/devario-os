#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
test_root="$(mktemp -d /tmp/devario-keyring-package.XXXXXX)"
cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT
fail() { echo "Keyring-package boundary test failed: $*" >&2; exit 1; }

# shellcheck source=../scripts/lib/repository.sh
source "$project_dir/scripts/lib/repository.sh"
for repository in devario-core devario-managed; do
  bundle="$test_root/$repository-bundle"; stage="$test_root/$repository-stage"
  package="$test_root/$repository-keyring-1-1-any.pkg.tar.zst"
  mkdir -p "$bundle" "$stage/usr/share/shelly/keyrings" "$stage/usr/share/devario/keyrings"
  if [[ "$repository" == devario-core ]]; then source_prefix=devario; else source_prefix=devario-managed; fi
  installed_prefix="$repository"
  printf '%s\n' public > "$bundle/$source_prefix.gpg"
  printf '%s\n' trusted > "$bundle/$source_prefix-trusted"
  printf '%s\n' revoked > "$bundle/$source_prefix-revoked"
  printf '%s\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA > "$bundle/active-signer"
  cp "$bundle/$source_prefix.gpg" "$stage/usr/share/shelly/keyrings/$installed_prefix.gpg"
  cp "$bundle/$source_prefix-trusted" "$stage/usr/share/shelly/keyrings/$installed_prefix-trusted"
  cp "$bundle/$source_prefix-revoked" "$stage/usr/share/shelly/keyrings/$installed_prefix-revoked"
  cp "$bundle/active-signer" "$stage/usr/share/devario/keyrings/$installed_prefix-active-signer"
  bsdtar -caf "$package" -C "$stage" usr
  devario_verify_keyring_package "$package" "$bundle" "$repository"
  for packaged_path in \
    "usr/share/shelly/keyrings/$installed_prefix.gpg" \
    "usr/share/shelly/keyrings/$installed_prefix-trusted" \
    "usr/share/shelly/keyrings/$installed_prefix-revoked" \
    "usr/share/devario/keyrings/$installed_prefix-active-signer"; do
    printf '%s\n' drift > "$stage/$packaged_path"
    bsdtar -caf "$package" -C "$stage" usr
    if devario_verify_keyring_package "$package" "$bundle" "$repository" \
        >"$test_root/stdout" 2>"$test_root/stderr"; then
      fail "$repository accepted drift in $packaged_path"
    fi
    case "$packaged_path" in
      *.gpg) cp "$bundle/$source_prefix.gpg" "$stage/$packaged_path" ;;
      *-trusted) cp "$bundle/$source_prefix-trusted" "$stage/$packaged_path" ;;
      *-revoked) cp "$bundle/$source_prefix-revoked" "$stage/$packaged_path" ;;
      *-active-signer) cp "$bundle/active-signer" "$stage/$packaged_path" ;;
    esac
  done
  rm -f -- "$stage/usr/share/shelly/keyrings/$installed_prefix-revoked"
  bsdtar -caf "$package" -C "$stage" usr
  if devario_verify_keyring_package "$package" "$bundle" "$repository" \
      >"$test_root/stdout" 2>"$test_root/stderr"; then
    fail "$repository accepted a missing empty revoked-key member"
  fi
done

echo 'Keyring-package boundary tests passed.'
