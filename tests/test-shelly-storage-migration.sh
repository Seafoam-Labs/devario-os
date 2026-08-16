#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
migrate="$project_dir/packages/devario-alpm-runtime/shelly-storage-migrate"
test_root="$(mktemp -d /tmp/devario-shelly-migration-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p \
  "$test_root/etc/pacman.d/gnupg" \
  "$test_root/etc/pacman.d/hooks" \
  "$test_root/etc/shelly.d/gnupg" \
  "$test_root/etc/shelly.d/hooks" \
  "$test_root/var/lib/pacman/local/base-1-1" \
  "$test_root/var/lib/shelly" \
  "$test_root/var/cache/pacman/pkg" \
  "$test_root/var/cache/shelly/pkg"
printf '%s\n' \
  '[options]' \
  'DBPath = /var/lib/pacman/' \
  'CacheDir = /var/cache/pacman/pkg/' \
  'GPGDir = /etc/pacman.d/gnupg/' \
  'HookDir = /etc/pacman.d/hooks/' \
  '[devario-core]' \
  'SigLevel = Required' \
  'Server = https://packages.example.test/core/$arch' \
  > "$test_root/etc/pacman.conf"
printf '%s\n' '%NAME%' base '' '%VERSION%' 1-1 '' '%ARCH%' x86_64 '' \
  > "$test_root/var/lib/pacman/local/base-1-1/desc"
printf 'cached package\n' > "$test_root/var/cache/pacman/pkg/base.pkg.tar.zst"
printf 'trusted key\n' > "$test_root/etc/pacman.d/gnupg/pubring.gpg"
printf 'custom hook\n' > "$test_root/etc/pacman.d/hooks/custom.hook"

"$migrate" --root "$test_root" --prepare
[[ -L "$test_root/var/lib/shelly" && "$(readlink "$test_root/var/lib/shelly")" == pacman ]]
[[ -L "$test_root/var/cache/shelly/pkg" ]]
[[ -L "$test_root/etc/shelly.d/gnupg" ]]
[[ -L "$test_root/etc/shelly.d/hooks" ]]
grep -Fq 'DBPath = /var/lib/shelly/' "$test_root/etc/shelly.conf"
grep -Fq 'Server = https://packages.example.test/core/$arch' "$test_root/etc/shelly.conf"
if grep -Eq '/etc/pacman\.(conf|d/(gnupg|hooks))|/var/(lib|cache)/pacman' \
  "$test_root/etc/shelly.conf"; then
  echo 'Migrated Shelly configuration retained a legacy runtime path.' >&2
  exit 1
fi

touch "$test_root/var/lib/pacman/db.lck"
if "$migrate" --root "$test_root" --finalize >/dev/null 2>&1; then
  echo 'Shelly storage migration ran while the package database was locked.' >&2
  exit 1
fi
rm -f "$test_root/var/lib/pacman/db.lck"

"$migrate" --root "$test_root" --finalize
for new_path in \
  var/lib/shelly \
  var/cache/shelly/pkg \
  etc/shelly.d/gnupg \
  etc/shelly.d/hooks; do
  [[ -d "$test_root/$new_path" && ! -L "$test_root/$new_path" ]]
done
[[ ! -e "$test_root/var/lib/pacman" ]]
[[ ! -e "$test_root/var/cache/pacman/pkg" ]]
[[ ! -e "$test_root/etc/pacman.d/gnupg" ]]
[[ ! -e "$test_root/etc/pacman.d/hooks" ]]
[[ ! -e "$test_root/etc/pacman.conf" ]]
[[ -f "$test_root/var/lib/shelly/local/base-1-1/desc" ]]
[[ -f "$test_root/var/cache/shelly/pkg/base.pkg.tar.zst" ]]
[[ -f "$test_root/etc/shelly.d/gnupg/pubring.gpg" ]]
[[ -f "$test_root/etc/shelly.d/hooks/custom.hook" ]]
[[ -f "$test_root/var/lib/devario/shelly-path-migration/complete" ]]

# Completion is idempotent and must not disturb already materialized state.
"$migrate" --root "$test_root" --finalize
[[ -f "$test_root/var/lib/shelly/local/base-1-1/desc" ]]

# The retained rollback path recreates current state for the previous Shelly
# package without changing the new primary paths.
"$migrate" --root "$test_root" --rollback
[[ -f "$test_root/var/lib/pacman/local/base-1-1/desc" ]]
[[ -f "$test_root/var/cache/pacman/pkg/base.pkg.tar.zst" ]]
[[ -f "$test_root/etc/pacman.d/gnupg/pubring.gpg" ]]
[[ -f "$test_root/etc/pacman.d/hooks/custom.hook" ]]
grep -Fq 'DBPath = /var/lib/pacman/' "$test_root/etc/pacman.conf"
[[ -f "$test_root/var/lib/devario/shelly-path-migration/rollback-ready" ]]

echo 'Shelly storage migration tests passed.'
