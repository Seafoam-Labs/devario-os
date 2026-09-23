#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
test_root="$(mktemp -d /tmp/devario-release-identity.XXXXXX)"
cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT
fail() { echo "Release-identity test failed: $*" >&2; exit 1; }

cp "$project_dir/iso/airootfs/etc/os-release" "$test_root/os-release"
"$project_dir/scripts/render-release-os-release.py" \
  --file "$test_root/os-release" --edition community --variant Community \
  --release-version 2026.08.14
for expected in \
  'PRETTY_NAME="Devario Community 2026.08.14"' \
  'VERSION="2026.08.14"' \
  'VERSION_ID="2026.08.14"' \
  'BUILD_ID="2026.08.14"'; do
  grep -Fxq "$expected" "$test_root/os-release" || fail "missing exact field: $expected"
done
if grep -Fqi Development "$test_root/os-release"; then
  fail 'rendered release retained a Development identity'
fi
if "$project_dir/scripts/render-release-os-release.py" \
    --file "$test_root/os-release" --edition community --variant Community \
    --release-version 2026.08.14 >/dev/null 2>&1; then
  fail 'already-rendered release identity was silently reused'
fi

for unsafe in '2026 08 14' '../2026' '2026@prod' '2026+prod' ''; do
  cp "$project_dir/iso/airootfs/etc/os-release" "$test_root/unsafe"
  if "$project_dir/scripts/render-release-os-release.py" \
      --file "$test_root/unsafe" --edition community --variant Community \
      --release-version "$unsafe" >/dev/null 2>&1; then
    fail "unsafe release version was accepted: $unsafe"
  fi
done

cp "$project_dir/iso/airootfs/etc/os-release" "$test_root/mismatch"
if "$project_dir/scripts/render-release-os-release.py" \
    --file "$test_root/mismatch" --edition managed --variant Managed \
    --release-version test >/dev/null 2>&1; then
  fail 'edition/os-release identity mismatch was accepted'
fi

echo 'Release-identity tests passed.'
