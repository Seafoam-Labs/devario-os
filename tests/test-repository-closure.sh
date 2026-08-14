#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
test_root="$(mktemp -d /tmp/devario-repository-closure.XXXXXX)"
repository="$test_root/repository"; package_root="$test_root/package"; database_root="$test_root/database"
cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT
fail() { echo "Repository-closure test failed: $*" >&2; exit 1; }
mkdir -p "$repository" "$package_root" "$database_root/fixture-1-1"

printf '%s\n' \
  'pkgname = fixture' \
  'pkgbase = fixture' \
  'pkgver = 1-1' \
  'arch = any' \
  'packager = ZoeyErinBauer <40698010+ZoeyErinBauer@users.noreply.github.com>' \
  > "$package_root/.PKGINFO"
package="$repository/fixture-1-1-any.pkg.tar.zst"
bsdtar -caf "$package" -C "$package_root" .PKGINFO
size="$(stat -c '%s' "$package")"
digest="$(sha256sum "$package")"; digest="${digest%% *}"
write_desc() {
  local locked_digest="$1"
  printf '%s\n' \
    '%NAME%' fixture '' \
    '%VERSION%' 1-1 '' \
    '%ARCH%' any '' \
    '%FILENAME%' "$(basename -- "$package")" '' \
    '%CSIZE%' "$size" '' \
    '%SHA256SUM%' "$locked_digest" '' \
    > "$database_root/fixture-1-1/desc"
}
write_desc "$digest"
for database in devario-core.db.tar.zst devario-core.files.tar.zst; do
  bsdtar -caf "$repository/$database" -C "$database_root" fixture-1-1/desc
done
ln -s devario-core.db.tar.zst "$repository/devario-core.db"
ln -s devario-core.files.tar.zst "$repository/devario-core.files"

# shellcheck source=../scripts/lib/repository.sh
source "$project_dir/scripts/lib/repository.sh"
devario_verify_repository "$repository" devario-core \
  "$project_dir/packages/devario-keyring" development

# Match repo-add --sign's actual four compatibility links. A signed
# development fixture uses a stubbed verifier; production exercises the same
# structural closure before invoking the real active-signer verifier.
printf '%s\n' signature > "$repository/devario-core.db.tar.zst.sig"
printf '%s\n' signature > "$repository/devario-core.files.tar.zst.sig"
ln -s devario-core.db.tar.zst.sig "$repository/devario-core.db.sig"
ln -s devario-core.files.tar.zst.sig "$repository/devario-core.files.sig"
devario_gpgv_active_signature() { return 0; }
devario_verify_repository "$repository" devario-core \
  "$project_dir/packages/devario-keyring" development
rm -f -- "$repository/devario-core.files.sig"
if devario_verify_repository "$repository" devario-core \
    "$project_dir/packages/devario-keyring" development \
    >"$test_root/stdout" 2>"$test_root/stderr"; then
  fail 'a signed repository missing the repo-add files.sig link was accepted'
fi
ln -s devario-core.files.tar.zst.sig "$repository/devario-core.files.sig"

write_desc "$(printf '0%.0s' {1..64})"
bsdtar -caf "$repository/devario-core.db.tar.zst" -C "$database_root" fixture-1-1/desc
if devario_verify_repository "$repository" devario-core \
    "$project_dir/packages/devario-keyring" development \
    >"$test_root/stdout" 2>"$test_root/stderr"; then
  fail 'a repository database with a substituted package digest was accepted'
fi

echo 'Repository-closure tests passed.'
