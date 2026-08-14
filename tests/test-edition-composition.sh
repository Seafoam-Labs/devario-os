#!/usr/bin/env bash
set -euo pipefail

# This behavior test creates its own ordinary, controlled-release, and action-
# snapshot identities below. Do not let a parent validator's authenticated
# action context alter the ordinary fixture cases.
unset DEVARIO_CORE_COMMIT
unset DEVARIO_VALIDATED_ACTION_SNAPSHOT
unset DEVARIO_ACTION_SNAPSHOT_ROOT
unset DEVARIO_ACTION_SNAPSHOT_SENTINEL

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
# shellcheck source=../scripts/lib/edition.sh
source "$project_dir/scripts/lib/edition.sh"

test_root="$(mktemp -d /tmp/devario-edition-test.XXXXXX)"
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "Edition composition test failed: $*" >&2
  exit 1
}

write_config() {
  local edition_dir="$1"
  local id="${2:-test}"
  mkdir -p "$edition_dir"
  printf '%s\n' \
    'format=1' \
    "id=$id" \
    'variant=Test Edition' \
    "iso_name=devario-$id" \
    'iso_label_prefix=DEVARIO_TEST' \
    'iso_publisher=Devario Project' \
    'iso_application=Devario Test Medium' \
    > "$edition_dir/edition.conf"
  : > "$edition_dir/packages.add"
  : > "$edition_dir/packages.remove"
  : > "$edition_dir/replacements.allow"
  : > "$edition_dir/package-sources.conf"
}

compose() {
  local core_dir="$1"
  local edition_dir="$2"
  local output_dir="$3"
  mkdir -p "$output_dir"
  devario_compose_profile \
    "$core_dir/archiso" "$edition_dir" "$output_dir" "$core_dir"
}

expect_failure() {
  local description="$1"
  shift
  if "$@" > "$test_root/failure.stdout" 2> "$test_root/failure.stderr"; then
    fail "$description unexpectedly succeeded"
  fi
  if ! grep -Fq 'Edition error:' "$test_root/failure.stderr"; then
    fail "$description did not report an edition error"
  fi
}

expect_contract_failure() {
  local description="$1"
  shift
  if "$@" > "$test_root/failure.stdout" 2> "$test_root/failure.stderr"; then
    fail "$description unexpectedly succeeded"
  fi
  if ! grep -Eq '^(Edition|Repository) error:' "$test_root/failure.stderr"; then
    fail "$description did not report an edition/package-source contract error"
  fi
}

make_core() {
  local core_dir="$1"
  mkdir -p "$core_dir/archiso/airootfs/etc" \
    "$core_dir/archiso/late-airootfs/usr/share/devario" \
    "$core_dir/editions"
  printf '%s\n' \
    aqueous \
    firefox \
    linux-cachyos-lts \
    shelly \
    > "$core_dir/archiso/packages.x86_64"
  printf '%s\n' 'base hostname' > "$core_dir/archiso/airootfs/etc/hostname"
  printf '%s\n' 'base data' \
    > "$core_dir/archiso/late-airootfs/usr/share/devario/base-data"
}

core="$test_root/core"
make_core "$core"

community="$core/editions/community"
write_config "$community" community
community_output="$test_root/community-output"
compose "$core" "$community" "$community_output"
cmp -s "$core/archiso/packages.x86_64" "$community_output/packages.x86_64" \
  || fail 'the empty Community edition changed the base package list'
cmp -s "$core/archiso/airootfs/etc/hostname" \
  "$community_output/airootfs/etc/hostname" \
  || fail 'the empty Community edition changed a base profile file'
if grep -RInE \
  'devario-managed|remora|managed-keyring|tenant_(id|url|token)|tenant-(id|url|token)' \
  "$community_output" > "$test_root/community-boundary.txt"; then
  cat "$test_root/community-boundary.txt" >&2
  fail 'the Community profile contains managed-edition identity, trust, or tenant data'
fi

add_remove="$core/editions/add-remove"
write_config "$add_remove" add-remove
printf '%s\n' thunderbird > "$add_remove/packages.add"
printf '%s\n' thunderbird=arch > "$add_remove/package-sources.conf"
printf '%s\n' firefox > "$add_remove/packages.remove"
mkdir -p "$add_remove/airootfs/etc/devario"
printf '%s\n' managed > "$add_remove/airootfs/etc/devario/channel"
add_remove_output="$test_root/add-remove-output"
compose "$core" "$add_remove" "$add_remove_output"
grep -Fxq thunderbird "$add_remove_output/packages.x86_64" \
  || fail 'an added package was not composed'
if grep -Fxq firefox "$add_remove_output/packages.x86_64"; then
  fail 'a removed optional package remains in the composed profile'
fi
grep -Fxq managed "$add_remove_output/airootfs/etc/devario/channel" \
  || fail 'a new overlay file was not composed'

collision="$core/editions/collision"
write_config "$collision" collision
mkdir -p "$collision/airootfs/etc"
printf '%s\n' replacement > "$collision/airootfs/etc/hostname"
expect_failure 'unapproved collision' compose \
  "$core" "$collision" "$test_root/collision-failure"
printf '%s\n' airootfs/etc/hostname > "$collision/replacements.allow"
collision_output="$test_root/collision-output"
compose "$core" "$collision" "$collision_output"
grep -Fxq replacement "$collision_output/airootfs/etc/hostname" \
  || fail 'an approved replacement was not composed'
printf '%s\n' airootfs/etc/not-present >> "$collision/replacements.allow"
expect_failure 'stale replacement allowlist entry' compose \
  "$core" "$collision" "$test_root/stale-allow-output"

bad_package="$core/editions/bad-package"
write_config "$bad_package" bad-package
printf '%s\n' aqueous > "$bad_package/packages.add"
printf '%s\n' aqueous=core > "$bad_package/package-sources.conf"
expect_failure 'addition of an existing package' compose \
  "$core" "$bad_package" "$test_root/add-existing-output"
printf '%s\n' 'not installed' > "$bad_package/packages.add"
: > "$bad_package/package-sources.conf"
expect_failure 'package name containing whitespace' compose \
  "$core" "$bad_package" "$test_root/bad-package-name-output"
: > "$bad_package/packages.add"
printf '%s\n' missing > "$bad_package/packages.remove"
expect_failure 'removal of an absent package' compose \
  "$core" "$bad_package" "$test_root/remove-missing-output"
printf '%s\n' shelly > "$bad_package/packages.remove"
expect_failure 'removal of an immutable package' compose \
  "$core" "$bad_package" "$test_root/remove-required-output"

duplicate="$core/editions/duplicate"
write_config "$duplicate" duplicate
printf '%s\n' thunderbird thunderbird > "$duplicate/packages.add"
expect_failure 'duplicate package addition' compose \
  "$core" "$duplicate" "$test_root/duplicate-output"

missing_origin="$core/editions/missing-origin"
write_config "$missing_origin" missing-origin
printf '%s\n' thunderbird > "$missing_origin/packages.add"
expect_contract_failure 'missing package origin mapping' compose \
  "$core" "$missing_origin" "$test_root/missing-origin-output"

extra_origin="$core/editions/extra-origin"
write_config "$extra_origin" extra-origin
printf '%s\n' thunderbird=arch > "$extra_origin/package-sources.conf"
expect_contract_failure 'extra package origin mapping' compose \
  "$core" "$extra_origin" "$test_root/extra-origin-output"

duplicate_origin="$core/editions/duplicate-origin"
write_config "$duplicate_origin" duplicate-origin
printf '%s\n' thunderbird > "$duplicate_origin/packages.add"
printf '%s\n' thunderbird=arch thunderbird=core > "$duplicate_origin/package-sources.conf"
expect_contract_failure 'duplicate package origin mapping' compose \
  "$core" "$duplicate_origin" "$test_root/duplicate-origin-output"

managed_community="$core/editions/managed-community"
write_config "$managed_community" community
printf '%s\n' devario-managed-agent > "$managed_community/packages.add"
printf '%s\n' devario-managed-agent=managed > "$managed_community/package-sources.conf"
expect_failure 'managed package origin in Community' compose \
  "$core" "$managed_community" "$test_root/managed-community-output"

bad_allow="$core/editions/bad-allow"
write_config "$bad_allow" bad-allow
printf '%s\n' 'airootfs/etc/*' > "$bad_allow/replacements.allow"
expect_failure 'glob in replacement allowlist' compose \
  "$core" "$bad_allow" "$test_root/glob-allow-output"
printf '%s\n' 'airootfs/etc/../hostname' > "$bad_allow/replacements.allow"
expect_failure 'traversal in replacement allowlist' compose \
  "$core" "$bad_allow" "$test_root/traversal-allow-output"

bad_link="$core/editions/bad-link"
write_config "$bad_link" bad-link
mkdir -p "$bad_link/airootfs/etc/devario"
ln -s ../../../../outside "$bad_link/airootfs/etc/devario/escape"
expect_failure 'escaping overlay symlink' compose \
  "$core" "$bad_link" "$test_root/escaping-link-output"
rm "$bad_link/airootfs/etc/devario/escape"
ln -s /etc/hostname "$bad_link/airootfs/etc/devario/absolute"
expect_failure 'absolute overlay symlink' compose \
  "$core" "$bad_link" "$test_root/absolute-link-output"

executable="$core/editions/executable"
write_config "$executable" executable
mkdir -p "$executable/airootfs/usr/lib/devario"
printf '%s\n' '#!/bin/sh' > "$executable/airootfs/usr/lib/devario/program"
chmod 0755 "$executable/airootfs/usr/lib/devario/program"
expect_failure 'executable overlay content' compose \
  "$core" "$executable" "$test_root/executable-output"

type_change="$core/editions/type-change"
write_config "$type_change" type-change
mkdir -p "$type_change/airootfs/etc/hostname"
printf '%s\n' airootfs/etc/hostname > "$type_change/replacements.allow"
expect_failure 'overlay path type change' compose \
  "$core" "$type_change" "$test_root/type-change-output"

bad_config="$core/editions/bad-config"
write_config "$bad_config" bad-config
printf '%s\n' 'unknown=value' >> "$bad_config/edition.conf"
expect_failure 'unknown edition config key' compose \
  "$core" "$bad_config" "$test_root/unknown-config-output"

# An edition outside devario-os must lock a clean core commit exactly. Use a
# dedicated committed fixture so the repository containing this test may remain
# under active development.
locked_core="$test_root/locked core"
make_core "$locked_core"
git -C "$locked_core" init -q
git -C "$locked_core" config user.name 'ZoeyErinBauer'
git -C "$locked_core" config user.email '40698010+ZoeyErinBauer@users.noreply.github.com'
git -C "$locked_core" add .
git -C "$locked_core" commit -qm base
locked_commit="$(git -C "$locked_core" rev-parse HEAD)"
external="$test_root/external edition"
write_config "$external" external
printf 'devario_os_commit=%s\n' "$locked_commit" > "$external/base.lock"
external_output="$test_root/external output"
compose "$locked_core" "$external" "$external_output"
printf '%s\n' 'devario_os_commit=0000000000000000000000000000000000000000' > "$external/base.lock"
if DEVARIO_CORE_COMMIT=0000000000000000000000000000000000000000 \
  compose "$locked_core" "$external" "$test_root/forged-override-output" >/dev/null 2>&1; then
  fail 'an ordinary composition accepted a caller-forged DEVARIO_CORE_COMMIT override'
fi
action_core="$test_root/action core"
mkdir "$action_core"
git -C "$locked_core" archive --format=tar HEAD | tar -C "$action_core" -xf -
action_sentinel="$test_root/action-snapshot.lock"
printf 'devario_os_commit=%s\n' "$locked_commit" > "$action_sentinel"
printf 'devario_os_commit=%s\n' "$locked_commit" > "$external/base.lock"
mkdir "$test_root/action-snapshot-output"
DEVARIO_CORE_COMMIT="$locked_commit" DEVARIO_VALIDATED_ACTION_SNAPSHOT=1 \
DEVARIO_ACTION_SNAPSHOT_ROOT="$action_core" DEVARIO_ACTION_SNAPSHOT_SENTINEL="$action_sentinel" \
  devario_compose_profile "$action_core/archiso" "$external" "$test_root/action-snapshot-output" "$action_core" action-snapshot
mkdir "$test_root/missing-sentinel-output"
if DEVARIO_CORE_COMMIT="$locked_commit" DEVARIO_VALIDATED_ACTION_SNAPSHOT=1 \
  DEVARIO_ACTION_SNAPSHOT_ROOT="$action_core" DEVARIO_ACTION_SNAPSHOT_SENTINEL="$test_root/missing" \
  devario_compose_profile "$action_core/archiso" "$external" "$test_root/missing-sentinel-output" "$action_core" action-snapshot >/dev/null 2>&1; then
  fail 'an action snapshot accepted a missing validation-only sentinel'
fi
printf '%s\n' 'devario_os_commit=0000000000000000000000000000000000000000' \
  > "$external/base.lock"
expect_failure 'mismatched external base lock' compose \
  "$locked_core" "$external" "$test_root/mismatched-lock-output"
printf '%s\n' 'not-a-lock' > "$external/base.lock"
expect_failure 'malformed external base lock' compose \
  "$locked_core" "$external" "$test_root/malformed-lock-output"
printf 'devario_os_commit=%s\n' "$locked_commit" > "$external/base.lock"
printf '%s\n' dirty > "$locked_core/untracked"
expect_failure 'dirty external base checkout' compose \
  "$locked_core" "$external" "$test_root/dirty-base-output"

echo 'Edition composition behavior tests passed.'
