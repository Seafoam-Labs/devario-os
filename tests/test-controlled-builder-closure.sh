#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
test_root="$(mktemp -d /tmp/devario-builder-closure.XXXXXX)"
cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT
fail() { echo "Controlled-builder closure test failed: $*" >&2; exit 1; }

printf '%s\n' exact > "$test_root/file"
baseline="$($project_dir/scripts/tree-closure-digest.py --root "$test_root")"
chmod 0755 "$test_root/file"
mode_changed="$($project_dir/scripts/tree-closure-digest.py --root "$test_root")"
[[ "$baseline" != "$mode_changed" ]] || fail 'file-mode tampering did not change the builder identity'
chmod 0644 "$test_root/file"
mkdir "$test_root/empty-directory"
directory_changed="$($project_dir/scripts/tree-closure-digest.py --root "$test_root")"
[[ "$baseline" != "$directory_changed" ]] || fail 'an added empty directory did not change the builder identity'
rmdir "$test_root/empty-directory"
printf '%s\n' changed > "$test_root/file"
content_changed="$($project_dir/scripts/tree-closure-digest.py --root "$test_root")"
[[ "$baseline" != "$content_changed" ]] || fail 'file-content tampering did not change the builder identity'

echo 'Controlled-builder closure tests passed.'
