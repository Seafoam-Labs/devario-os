#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
repo_dir="${DEVARIO_PACKAGE_OUTPUT_DIR:-$project_dir/repo/core}"
repository_name=devario-core
keyring_dir="${DEVARIO_KEYRING_DIR:-$project_dir/packages/devario-keyring}"
makepkg_adapter="$script_dir/makepkg-shelly-adapter.sh"
makepkg_config="$script_dir/makepkg-shelly.conf"
signing_key="${DEVARIO_SIGNING_KEY:-}"
signing_home="${DEVARIO_GNUPGHOME:-$project_dir/.devario-signing}"
key_policy="${DEVARIO_KEY_POLICY:-development}"
release_build="${DEVARIO_RELEASE_BUILD:-0}"
package_work_dir="${DEVARIO_PACKAGE_WORK_DIR:-}"
source_output_dir="${DEVARIO_SOURCE_OUTPUT_DIR:-}"
prepare_dependencies_only="${DEVARIO_BUILDER_PREPARE:-0}"
expected_packager='ZoeyErinBauer <40698010+ZoeyErinBauer@users.noreply.github.com>'
package_order=(
  devario-filesystem
  devario-keyring
  devario-base
  devario-boot
  ckbcomp
  calamares
)

usage() {
  cat <<'EOF'
Usage: ./scripts/build-packages.sh [package-directory ...]

Build every Devario package when no package directory is specified. Otherwise,
build only the requested package directories in the repository's canonical
order and refresh the repository database with all existing artifacts.

Release builds set DEVARIO_RELEASE_BUILD=1, use a production public-key bundle,
require the exact clean committed source tree, build the full package set into
fresh output/work directories, and emit corresponding source archives.
EOF
}

requested_packages=("$@")
declare -A known_package_directories=()
known_package_directories[shelly-arch-compat]=1
for package_name in "${package_order[@]}"; do
  known_package_directories["$package_name"]=1
done

declare -A requested_package_directories=()
for package_name in "${requested_packages[@]}"; do
  case "$package_name" in
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $package_name" >&2
      usage >&2
      exit 2
      ;;
  esac
  if [[ -z "${known_package_directories[$package_name]:-}" ]]; then
    echo "Unknown package directory: $package_name" >&2
    usage >&2
    exit 2
  fi
  requested_package_directories["$package_name"]=1
done

if [[ -n "${requested_package_directories[shelly-arch-compat]:-}" ]]; then
  package_order+=(shelly-arch-compat)
fi

selected_package_order=()
if (( ${#requested_package_directories[@]} == 0 )); then
  selected_package_order=("${package_order[@]}")
else
  for package_name in "${package_order[@]}"; do
    if [[ -n "${requested_package_directories[$package_name]:-}" ]]; then
      selected_package_order+=("$package_name")
    fi
  done
fi

if [[ "$release_build" != 0 && "$release_build" != 1 ]]; then
  echo 'DEVARIO_RELEASE_BUILD must be 0 or 1.' >&2
  exit 2
fi
if [[ "$prepare_dependencies_only" != 0 && "$prepare_dependencies_only" != 1 ]]; then
  echo 'DEVARIO_BUILDER_PREPARE must be 0 or 1.' >&2
  exit 2
fi
if (( release_build )) && (( ${#requested_package_directories[@]} != 0 )); then
  echo 'A release package build must rebuild the complete canonical package set.' >&2
  exit 1
fi

# shellcheck source=lib/repository.sh
source "$script_dir/lib/repository.sh"
devario_validate_keyring_bundle "$keyring_dir" "$repository_name" "$key_policy"

if [[ -n "$signing_key" ]]; then
  export GNUPGHOME="$signing_home"
  devario_require_active_secret_signer "$signing_home" "$signing_key"
  signing_key="$DEVARIO_SIGNING_FINGERPRINT"
fi

if (( release_build )); then
  if [[ "$key_policy" != production ]]; then
    echo 'A release package build requires the production key policy.' >&2
    exit 1
  fi
  if (( ! prepare_dependencies_only )) && [[ -z "$signing_key" ]]; then
    echo 'An artifact-producing release package build requires the active signer.' >&2
    exit 1
  fi
  if (( ! prepare_dependencies_only )); then
    if [[ "${DEVARIO_CONTROLLED_NSPAWN:-0}" != 1 \
      || "${DEVARIO_INPUT_LOCK:-}" != /input/CORE-INPUT-LOCK.json ]]; then
      echo 'Native or unauthenticated release package construction is forbidden.' >&2
      exit 1
    fi
    DEVARIO_KEYRING_DIR="$keyring_dir" DEVARIO_REPOSITORY_NAME="$repository_name" \
      "$script_dir/verify-controlled-builder.sh"
  fi
  if [[ "${DEVARIO_VERIFIED_SOURCE:-0}" != 1 ]]; then
    "$script_dir/verify-repository-boundary.sh" --repository "$project_dir"
  fi
  if [[ "${DEVARIO_VERIFIED_SOURCE:-0}" == 1 ]]; then
    "$script_dir/reject-secret-material.py" --tree "$project_dir"
  else
    "$script_dir/reject-secret-material.py" --git-tracked "$project_dir"
  fi
  expected_epoch="${DEVARIO_CORE_SOURCE_DATE_EPOCH:-}"
  if [[ -z "$expected_epoch" ]]; then
    expected_epoch="$(git -C "$project_dir" show -s --format=%ct HEAD 2>/dev/null || true)"
  fi
  if [[ ! "$expected_epoch" =~ ^[0-9]+$ \
    || "${SOURCE_DATE_EPOCH:-}" != "$expected_epoch" ]]; then
    echo 'Release SOURCE_DATE_EPOCH must equal the verified core commit timestamp.' >&2
    exit 1
  fi
fi

if (( EUID == 0 )); then
  echo "Build packages as a regular user; Shelly will request privilege for dependencies." >&2
  exit 1
fi

# shellcheck source=lib/python-env.sh
source "$script_dir/lib/python-env.sh"
devario_use_validation_python

for command_name in awk bsdtar find makepkg python3 repo-add shelly sort; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

if [[ ! -x "$makepkg_adapter" ]]; then
  echo "The strict makepkg Shelly adapter is not executable: $makepkg_adapter" >&2
  exit 1
fi

if [[ -z "$package_work_dir" ]]; then
  package_work_dir="$(mktemp -d /tmp/devario-package-build.XXXXXX)"
  cleanup_package_work=1
else
  package_work_dir="$(realpath -m -- "$package_work_dir")"
  cleanup_package_work=0
  if [[ -e "$package_work_dir" ]] \
    && [[ -n "$(find "$package_work_dir" -mindepth 1 -print -quit)" ]]; then
    echo "Package work directory must be fresh and empty: $package_work_dir" >&2
    exit 1
  fi
  install -d -m 0755 "$package_work_dir"
fi
cleanup() {
  if (( cleanup_package_work )); then
    rm -rf -- "$package_work_dir"
  fi
}
trap cleanup EXIT
package_artifact_dir="$package_work_dir/artifacts"
package_source_dir="$package_work_dir/sources"
package_build_dir="$package_work_dir/build"
install -d -m 0755 "$package_artifact_dir" "$package_source_dir" "$package_build_dir"
export DEVARIO_MAKEPKG_PKGDEST="$package_artifact_dir"
export DEVARIO_MAKEPKG_SRCPKGDEST="$package_source_dir"
export DEVARIO_MAKEPKG_BUILDDIR="$package_build_dir"

if (( release_build )); then
  if [[ -e "$repo_dir" ]] && [[ -n "$(find "$repo_dir" -mindepth 1 -print -quit)" ]]; then
    echo "Release repository output must be fresh and empty: $repo_dir" >&2
    exit 1
  fi
  [[ -n "$source_output_dir" ]] || source_output_dir="$(dirname -- "$repo_dir")/sources"
  if [[ -e "$source_output_dir" ]] \
    && [[ -n "$(find "$source_output_dir" -mindepth 1 -print -quit)" ]]; then
    echo "Release source output must be fresh and empty: $source_output_dir" >&2
    exit 1
  fi
  install -d -m 0755 "$source_output_dir"
fi
if [[ ! -r "$makepkg_config" ]]; then
  echo "The Shelly-only makepkg configuration is missing: $makepkg_config" >&2
  exit 1
fi

run_makepkg() {
  PACMAN="$makepkg_adapter" makepkg --config "$makepkg_config" "$@"
}

collect_build_dependencies() {
  local package_name package_dir package_srcinfo

  for package_name in "${selected_package_order[@]}"; do
    if [[ "$package_name" == devario-base \
      || "$package_name" == devario-keyring \
      || "$package_name" == seafoam-keyring \
      || "$package_name" == devario-filesystem \
      || "$package_name" == devario-aqueous-desktop ]]; then
      continue
    fi
    package_dir="$project_dir/packages/$package_name"
    if ! package_srcinfo="$(
      cd "$package_dir"
      run_makepkg --printsrcinfo
    )"; then
      echo "Could not read dependency metadata for $package_name." >&2
      return 1
    fi
    printf '%s\n' "$package_srcinfo"
  done | awk -F ' = ' '
    /^[[:space:]]*(depends|makedepends|checkdepends)(_[[:alnum:]_]+)? = / {
      if ($2 != "") {
        print $2
      }
    }
  ' | sort -u
}

declare -A local_package_names=()
for package_name in "${package_order[@]}"; do
  package_dir="$project_dir/packages/$package_name"
  if ! package_srcinfo="$(
    cd "$package_dir"
    run_makepkg --printsrcinfo
  )"; then
    echo "Could not read local package names for $package_name." >&2
    exit 1
  fi
  while IFS= read -r local_package_name; do
    [[ -n "$local_package_name" ]] || continue
    local_package_names["$local_package_name"]=1
  done < <(
    awk -F ' = ' '/^pkgname = / { print $2 }' <<< "$package_srcinfo"
  )
done

if ! reported_dependencies_text="$(collect_build_dependencies)"; then
  echo "Dependency collection failed; refusing a partial --nodeps build." >&2
  exit 1
fi
reported_dependencies=()
if [[ -n "$reported_dependencies_text" ]]; then
  mapfile -t reported_dependencies <<< "$reported_dependencies_text"
fi

# PKGBUILDs assume the standard package-construction toolchain is present and
# do not repeat those implicit dependencies in each recipe.
build_dependencies=('base-devel')
for dependency in "${reported_dependencies[@]}"; do
  dependency_name="${dependency%%[<>=]*}"
  # Locally built packages are not build inputs. The host Shelly installation
  # already guarantees libalpm is present, while the Devario runtime package
  # replaces that provider only inside the resulting repository and image.
  if [[ -n "${local_package_names[$dependency_name]:-}" || "$dependency_name" == libalpm.so ]]; then
    continue
  fi
  build_dependencies+=("$dependency")
done

if (( ${#build_dependencies[@]} )); then
  echo "Synchronizing repositories through Shelly..."
  shelly sync standard --no-confirm
  echo "Installing package build dependencies through Shelly..."
  shelly install standard --no-confirm "${build_dependencies[@]}"
fi

if (( prepare_dependencies_only )); then
  echo 'Builder dependency preparation completed without producing artifacts.'
  exit 0
fi

mkdir -p "$repo_dir"

printf 'Building package directories:'
printf ' %s' "${selected_package_order[@]}"
printf '\n'

for package_name in "${selected_package_order[@]}"; do
  package_dir="$project_dir/packages/$package_name"
  if [[ ! -f "$package_dir/PKGBUILD" ]]; then
    echo "Missing package recipe: $package_dir/PKGBUILD" >&2
    exit 1
  fi

  # A forced rebuild can produce different bytes at the same package path.
  # Remove any old detached signatures before makepkg so a successful signed
  # build must create a matching signature for the new artifact.
  mapfile -t expected_artifacts < <(
    cd "$package_dir"
    run_makepkg --packagelist
  )
  for expected_artifact in "${expected_artifacts[@]}"; do
    rm -f -- "$expected_artifact.sig"
  done

  # Dependencies were installed explicitly through Shelly above. --nodeps
  # prevents makepkg from invoking its configured package-manager hook for
  # dependency resolution; the strict adapter permits only its final -Qi
  # inventory query used to write .BUILDINFO.
  build_args=(--clean --cleanbuild --force --noconfirm --nodeps)
  if [[ -n "$signing_key" ]]; then
    build_args+=(--sign --key "$signing_key")
  fi

  (
    cd "$package_dir"
    run_makepkg "${build_args[@]}"
  )

  mapfile -t artifacts < <(
    cd "$package_dir"
    run_makepkg --packagelist
  )
  if (( ${#artifacts[@]} == 0 )); then
    echo "$package_name built successfully, but no package artifact was reported." >&2
    exit 1
  fi

  # With debug enabled, makepkg --packagelist predicts an automatic
  # $pkgbase-debug archive before it knows whether the package contains any
  # eligible binaries. Data-only and metapackages legitimately finish without
  # creating that predicted archive. Ignore only that undeclared automatic
  # debug output; every declared or otherwise predicted package remains
  # mandatory.
  package_srcinfo="$(cd "$package_dir" && run_makepkg --printsrcinfo)"
  package_base="$(
    awk -F ' = ' '/^pkgbase = / { print $2; exit }' <<< "$package_srcinfo"
  )"
  declared_debug_package=0
  if awk -F ' = ' -v debug_name="${package_base}-debug" \
    '$1 == "pkgname" && $2 == debug_name { found=1 } END { exit !found }' \
    <<< "$package_srcinfo"; then
    declared_debug_package=1
  fi

  built_artifacts=()
  for artifact in "${artifacts[@]}"; do
    if [[ ! -f "$artifact" ]]; then
      if (( ! declared_debug_package )) \
        && [[ "$(basename -- "$artifact")" == "${package_base}-debug-"* ]]; then
        continue
      fi
      echo "Expected package artifact is missing: $artifact" >&2
      exit 1
    fi
    built_artifacts+=("$artifact")
    artifact_packager="$(bsdtar -xOf "$artifact" .PKGINFO | awk -F ' = ' '$1 == "packager" {print $2; exit}')"
    buildinfo_packager="$(bsdtar -xOf "$artifact" .BUILDINFO | awk -F ' = ' '$1 == "packager" {print $2; exit}')"
    if [[ "$artifact_packager" != "$expected_packager" || "$buildinfo_packager" != "$expected_packager" ]]; then
      echo "Package attribution differs from the required ZoeyErinBauer identity: $artifact" >&2
      exit 1
    fi
  done
  artifacts=("${built_artifacts[@]}")
  if (( ${#artifacts[@]} == 0 )); then
    echo "$package_name did not create any package artifacts." >&2
    exit 1
  fi

  if (( release_build )); then
    # Emit the complete makepkg source archive from the same exact snapshot.
    # It is kept outside the binary ALPM repository so repository closure and
    # corresponding-source publication remain independently auditable.
    (
      cd "$package_dir"
      run_makepkg --allsource --force --noconfirm
    )
    shopt -s nullglob
    source_archives=("$package_source_dir/${package_base}-"*.src.tar.*)
    shopt -u nullglob
    if (( ${#source_archives[@]} != 1 )); then
      echo "$package_name must produce exactly one corresponding-source archive." >&2
      exit 1
    fi
    install -m 0444 "${source_archives[0]}" \
      "$source_output_dir/$(basename -- "${source_archives[0]}")"
    source_destination="$source_output_dir/$(basename -- "${source_archives[0]}")"
    GNUPGHOME="$signing_home" gpg --batch --yes --detach-sign \
      --local-user "$signing_key" --output "$source_destination.sig" \
      "$source_destination"
    chmod 0444 "$source_destination.sig"
    devario_gpgv_active_signature "$source_destination.sig" "$source_destination"
  fi

  # Keep only the just-built version of every output package. repo-add --remove
  # updates database entries but intentionally leaves superseded archives on
  # disk; those stale files make the release directory ambiguous and can be
  # selected accidentally by later glob-based tooling.
  declare -A built_artifact_basenames=()
  declare -A artifact_package_names=()
  for artifact in "${artifacts[@]}"; do
    artifact_basename="$(basename -- "$artifact")"
    built_artifact_basenames["$artifact_basename"]=1
    artifact_pkgname="$(
      bsdtar -xOf "$artifact" .PKGINFO \
        | awk -F ' = ' '$1 == "pkgname" { print $2; exit }'
    )"
    if [[ -z "$artifact_pkgname" ]]; then
      echo "Could not determine the package name for $artifact" >&2
      exit 1
    fi
    artifact_package_names["$artifact_pkgname"]=1
  done

  shopt -s nullglob
  for artifact_pkgname in "${!artifact_package_names[@]}"; do
    repository_artifacts=(
      "$repo_dir/${artifact_pkgname}-"*.pkg.tar.zst
      "$repo_dir/${artifact_pkgname}-"*.pkg.tar.zst.sig
    )
    for repository_artifact in "${repository_artifacts[@]}"; do
      repository_basename="$(basename -- "$repository_artifact")"
      unsigned_basename="${repository_basename%.sig}"
      if [[ -z "${built_artifact_basenames[$unsigned_basename]:-}" ]]; then
        rm -f -- "$repository_artifact"
      fi
    done
  done
  shopt -u nullglob

  for artifact in "${artifacts[@]}"; do
    install -Dm644 "$artifact" "$repo_dir/$(basename -- "$artifact")"
    if [[ -n "$signing_key" ]]; then
      if [[ ! -f "$artifact.sig" ]]; then
        echo "Expected package signature is missing: $artifact.sig" >&2
        exit 1
      fi
      install -Dm644 "$artifact.sig" "$repo_dir/$(basename -- "$artifact").sig"
    else
      # Optional signature checking still rejects an invalid signature when
      # one is present, so never retain a signature from an older build.
      rm -f -- "$repo_dir/$(basename -- "$artifact").sig"
    fi
  done
done

shopt -s nullglob
repo_packages=("$repo_dir"/*.pkg.tar.zst)
if (( ${#repo_packages[@]} == 0 )); then
  echo "No package artifacts are available for the Devario repository." >&2
  exit 1
fi

repo_args=(--remove)
# repo-add must never reuse a signature for the previous database contents.
rm -f -- \
  "$repo_dir/$repository_name.db.tar.zst.sig" \
  "$repo_dir/$repository_name.db.sig" \
  "$repo_dir/$repository_name.files.tar.zst.sig" \
  "$repo_dir/$repository_name.files.sig"
if [[ -n "$signing_key" ]]; then
  repo_args+=(--sign --key "$signing_key")
fi
repo-add "${repo_args[@]}" "$repo_dir/$repository_name.db.tar.zst" "${repo_packages[@]}"
rm -f -- \
  "$repo_dir/$repository_name.db.tar.zst.old" \
  "$repo_dir/$repository_name.db.tar.zst.old.sig" \
  "$repo_dir/$repository_name.files.tar.zst.old" \
  "$repo_dir/$repository_name.files.tar.zst.old.sig"
core_package_policy=strict
if (( ! release_build )) && [[ -z "$signing_key" ]]; then core_package_policy=local-installer; fi
devario_verify_repository "$repo_dir" "$repository_name" "$keyring_dir" "$key_policy" "$core_package_policy"
echo "Local repository is ready at $repo_dir"
