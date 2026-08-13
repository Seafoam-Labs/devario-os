#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
repo_dir="$project_dir/repo"
makepkg_adapter="$script_dir/makepkg-shelly-adapter.sh"
makepkg_config="$script_dir/makepkg-shelly.conf"
signing_key="${DEVARIO_SIGNING_KEY:-}"
signing_home="${DEVARIO_GNUPGHOME:-$project_dir/.devario-signing}"
package_order=(
  devario-alpm-runtime
  devario-keyring
  devario-base
  linux-cachyos-lts
  shelly
  ckbcomp
  noctalia
  noctalia-greeter
  aqueous
  devario-aqueous-desktop
  calamares
)

usage() {
  cat <<'EOF'
Usage: ./scripts/build-packages.sh [package-directory ...]

Build every Devario package when no package directory is specified. Otherwise,
build only the requested package directories in the repository's canonical
order and refresh the repository database with all existing artifacts.
EOF
}

requested_packages=("$@")
declare -A known_package_directories=()
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

if [[ -z "$signing_key" && -s "$signing_home/fingerprint" ]]; then
  read -r signing_key < "$signing_home/fingerprint"
fi
if [[ -n "$signing_key" ]]; then
  export GNUPGHOME="$signing_home"
fi

if (( EUID == 0 )); then
  echo "Build packages as a regular user; Shelly will request privilege for dependencies." >&2
  exit 1
fi

for command_name in awk bsdtar makepkg repo-add shelly sort; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

if [[ ! -x "$makepkg_adapter" ]]; then
  echo "The strict makepkg Shelly adapter is not executable: $makepkg_adapter" >&2
  exit 1
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
  done
  artifacts=("${built_artifacts[@]}")
  if (( ${#artifacts[@]} == 0 )); then
    echo "$package_name did not create any package artifacts." >&2
    exit 1
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

  # Aqueous's package check uses Noctalia's official plugin validator. Install
  # the just-built pinned Noctalia artifact through Shelly before reaching the
  # Aqueous build, keeping even this inter-package build edge Shelly-only.
  if [[ "$package_name" == noctalia ]]; then
    echo "Installing the pinned Noctalia build for Aqueous validation through Shelly..."
    shelly install standard --no-confirm "${artifacts[@]}"
  fi
done

shopt -s nullglob
repo_packages=("$repo_dir"/*.pkg.tar.zst)
if (( ${#repo_packages[@]} == 0 )); then
  echo "No package artifacts are available for the Devario repository." >&2
  exit 1
fi

repo_args=(--remove)
# repo-add must never reuse a signature for the previous database contents.
rm -f -- "$repo_dir/devario.db.tar.zst.sig" "$repo_dir/devario.db.sig"
if [[ -n "$signing_key" ]]; then
  repo_args+=(--sign --key "$signing_key")
fi
repo-add "${repo_args[@]}" "$repo_dir/devario.db.tar.zst" "${repo_packages[@]}"
rm -f -- \
  "$repo_dir/devario.db.tar.zst.old" \
  "$repo_dir/devario.db.tar.zst.old.sig" \
  "$repo_dir/devario.files.tar.zst.old" \
  "$repo_dir/devario.files.tar.zst.old.sig"
echo "Local repository is ready at $repo_dir"
