#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
test_root="$(mktemp -d /tmp/devario-image-boundary-test.XXXXXX)"
image_root="$test_root/root"
cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT
fail() { echo "Image-boundary test failed: $*" >&2; exit 1; }
expect_rejection() {
  local label="$1"
  local rejected_edition="${2:-community}"
  if "$project_dir/scripts/verify-image-boundary.sh" --root "$image_root" --edition "$rejected_edition" \
      >"$test_root/stdout" 2>"$test_root/stderr"; then
    fail "$label was accepted"
  fi
}

mkdir -p "$image_root/etc" "$image_root/var/lib/pacman/local/base-1-1"
printf '%s\n' \
  '[options]' \
  'Architecture = auto' \
  '[devario-core]' \
  'SigLevel = Required' \
  'Server = https://packages.example.test/devario-core' \
  > "$image_root/etc/pacman.conf"
printf '%s\n' \
  '%NAME%' base '' \
  '%VERSION%' 1-1 '' \
  '%ARCH%' x86_64 '' \
  '%BASE%' base '' \
  '%LICENSE%' GPL-2.0-only '' \
  '%PACKAGER%' 'ZoeyErinBauer <40698010+ZoeyErinBauer@users.noreply.github.com>' '' \
  > "$image_root/var/lib/pacman/local/base-1-1/desc"

inventory="$test_root/IMAGE-PACKAGE-INVENTORY.json"
"$project_dir/scripts/verify-image-boundary.sh" --root "$image_root" --edition community \
  --write-inventory "$inventory" >/dev/null
grep -Fq '"packager":"ZoeyErinBauer <40698010+ZoeyErinBauer@users.noreply.github.com>"' "$inventory" \
  || fail 'canonical inventory omitted exact package attribution'

printf '%s\n' '[seafoam-labs]' 'Server = https://packages.example.test/seafoam' >> "$image_root/etc/pacman.conf"
expect_rejection 'unexpected secondary repository'
sed -i '/^\[seafoam-labs\]$/,$d' "$image_root/etc/pacman.conf"

printf '%s\n' managed > "$image_root/etc/devario-managed-agent.conf"
expect_rejection 'managed pathname in Community'
rm -f -- "$image_root/etc/devario-managed-agent.conf"
printf '%s\n' tenant_token > "$image_root/etc/arbitrary.bin"
expect_rejection 'customer/tenant content in Community'
rm -f -- "$image_root/etc/arbitrary.bin"
printf '%s\n' 'Server = https://build-user:embedded-password@packages.example.test/core' \
  > "$image_root/etc/arbitrary.bin"
expect_rejection 'URL userinfo credential in Community'
rm -f -- "$image_root/etc/arbitrary.bin"

# Managed product names are allowed in a Managed image, but customer identity,
# enrollment material, and generic credentials are never image inputs.
printf '%s\n' \
  '[devario-managed]' \
  'SigLevel = Required' \
  'Server = https://packages.example.test/devario-managed' \
  >> "$image_root/etc/pacman.conf"
printf '%s\n' managed-product-code > "$image_root/etc/devario-managed-agent.conf"
"$project_dir/scripts/verify-image-boundary.sh" --root "$image_root" --edition managed >/dev/null
printf '%s\n' customer-id > "$image_root/etc/customer-id"
expect_rejection 'customer identifier pathname in Managed' managed
rm -f -- "$image_root/etc/customer-id"
printf '%s\n' enrollment_secret > "$image_root/etc/arbitrary.bin"
expect_rejection 'enrollment credential content in Managed' managed
rm -f -- "$image_root/etc/arbitrary.bin"
printf '%s\n' 'https://device:enrollment-secret@enroll.example.test/api' \
  > "$image_root/etc/arbitrary.bin"
expect_rejection 'URL userinfo credential in Managed' managed
rm -f -- "$image_root/etc/arbitrary.bin" "$image_root/etc/devario-managed-agent.conf"
sed -i '/^\[devario-managed\]$/,$d' "$image_root/etc/pacman.conf"
sed -i 's/SigLevel = Required/SigLevel = Optional TrustAll/' "$image_root/etc/pacman.conf"
expect_rejection 'weak repository trust'

echo 'Image-boundary tests passed.'
