#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
usage() {
  echo 'Usage: ./scripts/stage-installer-packages.sh DIRECTORY'
  echo 'Merge the seven locally built OS packages into repo/core without signing them.'
}
if (( $# == 1 )) && [[ "$1" == --help ]]; then usage; exit 0; fi
if (( $# != 1 )); then usage >&2; exit 2; fi
artifacts_dir="$(realpath -e -- "$1")"
repo_dir="$(realpath -e -- "${DEVARIO_CORE_REPO_DIR:-$project_dir/repo/core}")"
keyring_dir="${DEVARIO_CORE_KEYRING_DIR:-$project_dir/packages/devario-keyring}"
# shellcheck source=lib/repository.sh
source "$script_dir/lib/repository.sh"
expected=(calamares ckbcomp devario-filesystem devario-keyring devario-boot devario-base devario-system-integration)
declare -A artifacts=()
shopt -s nullglob
for artifact in "$artifacts_dir"/*.pkg.tar.zst; do
  name="$(bsdtar -xOf "$artifact" .PKGINFO | awk -F ' = ' '$1 == "pkgname" { print $2 }')"
  devario_is_local_installer_package "$name" || { echo "Unexpected local package: $name" >&2; exit 1; }
  [[ -z "${artifacts[$name]:-}" ]] || { echo "Duplicate local package: $name" >&2; exit 1; }
  artifacts[$name]="$artifact"
done
for name in "${expected[@]}"; do
  [[ -n "${artifacts[$name]:-}" ]] || { echo "Missing local package: $name" >&2; exit 1; }
done

echo 'Verifying the existing repository and downloaded package signatures...'
devario_verify_repository "$repo_dir" devario-core "$keyring_dir" development local-installer
stage="$(mktemp -d "${repo_dir}.installer.XXXXXX")"
cleanup() { rm -rf -- "$stage"; }
trap cleanup EXIT
cp -a --reflink=auto "$repo_dir/." "$stage/"
for artifact in "$stage"/*.pkg.tar.zst; do
  name="$(bsdtar -xOf "$artifact" .PKGINFO | awk -F ' = ' '$1 == "pkgname" { print $2 }')"
  if devario_is_local_installer_package "$name"; then rm -f -- "$artifact" "$artifact.sig"; fi
done
for name in "${expected[@]}"; do
  artifact="${artifacts[$name]}"
  install -m644 "$artifact" "$stage/$(basename -- "$artifact")"
  if [[ -e "$artifact.sig" || -L "$artifact.sig" ]]; then
    install -m644 "$artifact.sig" "$stage/$(basename -- "$artifact").sig"
  fi
done
# The downloaded package signatures remain intact. Only locally regenerated
# database metadata loses its old signature; it is checked against every archive.
rm -f -- "$stage"/devario-core.{db,files}{,.tar.zst}{,.sig}
shelly repo-db add "$stage/devario-core.db.tar.zst" "$stage"/*.pkg.tar.zst
# Shelly releases its flock but retains the sidecar. This private staging tree
# has no other writer; omit the inactive lock from the published closure.
rm -f -- "$stage/devario-core.db.tar.zst.lock"
echo 'Verifying the regenerated repository and local installer inputs...'
devario_verify_repository "$stage" devario-core "$keyring_dir" development local-installer
python3 "$script_dir/audit-iso-repositories.py" --database devario-core "$stage/devario-core.db" \
  --packages "$project_dir/iso/packages.x86_64" --output "${stage}-dependency-audit.json"
python3 "$script_dir/audit-iso-package-paths.py" --files "$stage/devario-core.files" \
  --dependency-audit "${stage}-dependency-audit.json" --output "${stage}-path-audit.json"
backup="${repo_dir}.before-installer-$(date +%Y%m%d%H%M%S)-$$"
mv -- "$repo_dir" "$backup"
if ! mv -- "$stage" "$repo_dir"; then
  mv -- "$backup" "$repo_dir"
  exit 1
fi
for kind in dependency path; do
  mv -- "${stage}-${kind}-audit.json" "${repo_dir}-${kind}-audit.json"
done
trap - EXIT
echo "ISO repository prepared at $repo_dir; previous snapshot preserved at $backup"
