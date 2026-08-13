#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
profile_dir="$project_dir/archiso"
edition_dir="$project_dir/editions/community"
repo_dir="$project_dir/repo"
output_dir="${DEVARIO_OUTPUT_DIR:-$project_dir/out}"
work_dir="${DEVARIO_WORK_DIR:-$project_dir/work}"
runtime_repo_url="${DEVARIO_REPO_URL:-}"
devario_keyring_source="$project_dir/packages/devario-keyring"
release_keyring="$devario_keyring_source/devario.gpg"
archiso_bundle_dir="$project_dir/tools/devario-archiso"
archiso_archive="$archiso_bundle_dir/archiso-v89.tar.gz"
archiso_patch="$archiso_bundle_dir/0001-bootstrap-with-shelly.patch"
archiso_late_overlay_patch="$archiso_bundle_dir/0002-copy-late-airootfs-after-packages.patch"
archiso_package_verification_patch="$archiso_bundle_dir/0003-verify-installed-packages.patch"
archiso_archive_sha256='d4e98484aaa4880888765cdc8ee9bcabed98320c3e6372b5d9699e32d1a33040'

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/build-iso.sh [--edition DIRECTORY]

Compose the base Archiso profile with Community by default, or with the strict
edition contract rooted at DIRECTORY, then build the resulting ISO.
EOF
}

while (( $# )); do
  case "$1" in
    --edition)
      if (( $# < 2 )); then
        echo '--edition requires a directory argument.' >&2
        usage >&2
        exit 2
      fi
      edition_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$edition_dir" != /* ]]; then
  edition_dir="$project_dir/$edition_dir"
fi

if [[ ! -r "$script_dir/lib/edition.sh" ]]; then
  echo 'The edition composition library is missing.' >&2
  exit 1
fi
# shellcheck source=lib/edition.sh
source "$script_dir/lib/edition.sh"

if (( EUID != 0 )); then
  echo "mkarchiso must run as root. Use: sudo $0" >&2
  exit 1
fi

for build_command in awk bash bsdtar chmod cp find git gpg grep install mv patch readlink realpath sha256sum; do
  if ! command -v "$build_command" >/dev/null 2>&1; then
    echo "$build_command is required to prepare the Shelly-enabled Archiso builder." >&2
    exit 1
  fi
done

if [[ ! -f "$archiso_archive" || ! -f "$archiso_patch" \
  || ! -f "$archiso_late_overlay_patch" \
  || ! -f "$archiso_package_verification_patch" ]]; then
  echo "The bundled Archiso source or a Devario patch is missing." >&2
  exit 1
fi
actual_archiso_sha256="$(sha256sum "$archiso_archive")"
actual_archiso_sha256="${actual_archiso_sha256%% *}"
if [[ "$actual_archiso_sha256" != "$archiso_archive_sha256" ]]; then
  echo "The bundled Archiso source archive failed its SHA-256 check." >&2
  exit 1
fi

if [[ ! -f "$repo_dir/devario.db.tar.zst" ]]; then
  echo "The local repository is missing. Run ./scripts/build-packages.sh first." >&2
  exit 1
fi

if [[ ! -f "$profile_dir/pacman.runtime.conf" ]]; then
  echo "The installed-system package-manager template is missing." >&2
  exit 1
fi

mkdir -p "$output_dir" "$work_dir"

generated_conf="$(mktemp /tmp/devario-alpm.XXXXXX.conf)"
staged_repo="$(mktemp -d /tmp/devario-repo.XXXXXX)"
staged_profile="$(mktemp -d /tmp/devario-profile.XXXXXX)"
archiso_source="$(mktemp -d /tmp/devario-archiso.XXXXXX)"
shelly_root="$(mktemp -d "$work_dir/.devario-shelly.XXXXXX")"
build_gpgdir="$(mktemp -d "$work_dir/.devario-keyring.XXXXXX")"
cleanup() {
  rm -f -- "$generated_conf"
  rm -rf -- "$staged_repo"
  rm -rf -- "$staged_profile"
  rm -rf -- "$archiso_source"
  rm -rf -- "$shelly_root"
  rm -rf -- "$build_gpgdir"
}
trap cleanup EXIT

# Stage the local repository under a short, root-readable path consumed by the
# isolated Shelly target transaction.
cp -a -- "$repo_dir/." "$staged_repo/"
chmod 755 "$staged_repo"
find "$staged_repo" -type f -exec chmod 444 {} +

devario_compose_profile \
  "$profile_dir" "$edition_dir" "$staged_profile" "$project_dir"
echo "Building Devario $DEVARIO_EDITION_VARIANT edition ($DEVARIO_EDITION_ID)."

shopt -s nullglob
repo_packages=("$staged_repo"/*.pkg.tar.zst)
if (( ${#repo_packages[@]} == 0 )); then
  echo "The Devario repository contains no package archives." >&2
  exit 1
fi

# Shelly currently succeeds even when an explicitly requested package is not
# available. Verify every Devario-owned image package before starting the much
# more expensive Archiso transaction so a stale or incomplete local repository
# cannot produce a kernel-less target root.
required_devario_packages=(
  aqueous
  aqueous-noctalia
  aqueous-session
  calamares
  ckbcomp
  devario-alpm-runtime
  devario-aqueous-desktop
  devario-base
  devario-keyring
  linux-cachyos-lts
  linux-cachyos-lts-headers
  noctalia
  noctalia-greeter
  shelly
)
declare -A repository_package_counts=()
for package_path in "${repo_packages[@]}"; do
  package_name="$(
    bsdtar -xOf "$package_path" .PKGINFO \
      | awk -F ' = ' '$1 == "pkgname" { print $2; exit }'
  )"
  if [[ -z "$package_name" ]]; then
    echo "Could not determine the package name for $package_path." >&2
    exit 1
  fi
  (( repository_package_counts["$package_name"] += 1 )) || true
done

missing_devario_packages=()
duplicate_devario_packages=()
for package_name in "${required_devario_packages[@]}"; do
  package_count="${repository_package_counts[$package_name]:-0}"
  if (( package_count == 0 )); then
    missing_devario_packages+=("$package_name")
  elif (( package_count > 1 )); then
    duplicate_devario_packages+=("$package_name")
  fi
done
if (( ${#missing_devario_packages[@]} || ${#duplicate_devario_packages[@]} )); then
  echo "The local Devario repository is incomplete or ambiguous." >&2
  if (( ${#missing_devario_packages[@]} )); then
    echo "Missing required package artifacts: ${missing_devario_packages[*]}" >&2
  fi
  if (( ${#duplicate_devario_packages[@]} )); then
    echo "Packages with multiple artifacts: ${duplicate_devario_packages[*]}" >&2
  fi
  echo "Build and sign the required packages before constructing the ISO." >&2
  echo "For the custom kernel, run:" >&2
  echo "  sudo ./scripts/build-packages-nspawn.sh linux-cachyos-lts" >&2
  exit 1
fi

shelly_packages=("$staged_repo"/shelly-[0-9]*.pkg.tar.zst)
if (( ${#shelly_packages[@]} != 1 )); then
  echo "The Devario repository must contain exactly one Shelly package." >&2
  exit 1
fi

if [[ -n "$runtime_repo_url" ]]; then
  if [[ "$runtime_repo_url" != https://?* \
    || "$runtime_repo_url" == *$'\n'* \
    || "$runtime_repo_url" == *$'\r'* ]]; then
    echo "DEVARIO_REPO_URL must use HTTPS for a release image." >&2
    exit 1
  fi
  for release_command in gpgv bsdtar cmp; do
    if ! command -v "$release_command" >/dev/null 2>&1; then
      echo "$release_command is required to verify a release repository." >&2
      exit 1
    fi
  done
  if [[ ! -s "$release_keyring" ]]; then
    echo "The packaged Devario public key is missing." >&2
    exit 1
  fi
  install -m444 "$release_keyring" "$staged_repo/.devario-release-key.gpg"
  release_keyring="$staged_repo/.devario-release-key.gpg"
  if [[ ! -s "$staged_repo/devario.db.tar.zst.sig" ]]; then
    echo "A release image requires a signed Devario repository database." >&2
    exit 1
  fi
  if ! gpgv --keyring "$release_keyring" \
    "$staged_repo/devario.db.tar.zst.sig" \
    "$staged_repo/devario.db.tar.zst"; then
    echo "The repository database signature does not match the packaged Devario key." >&2
    exit 1
  fi

  keyring_packages=("$staged_repo"/devario-keyring-[0-9]*.pkg.tar.zst)
  if (( ${#keyring_packages[@]} != 1 )); then
    echo "A release repository must contain exactly one Devario keyring package." >&2
    exit 1
  fi
  if ! cmp -s "$release_keyring" \
    <(bsdtar -xOf "${keyring_packages[0]}" usr/share/pacman/keyrings/devario.gpg); then
    echo "The Devario keyring package does not contain the release verification key." >&2
    exit 1
  fi

  for package_path in "${repo_packages[@]}"; do
    if [[ ! -s "$package_path.sig" ]]; then
      echo "A release image requires a signature for $(basename -- "$package_path")." >&2
      exit 1
    fi
    if ! gpgv --keyring "$release_keyring" "$package_path.sig" "$package_path"; then
      echo "The signature for $(basename -- "$package_path") does not match the packaged Devario key." >&2
      exit 1
    fi
  done
  runtime_siglevel="Required"
  runtime_server="$runtime_repo_url"
else
  # Development images retain a copy of the build repository so the installed
  # system can reinstall its core Devario packages without network access.
  runtime_siglevel="Optional TrustAll"
  runtime_server="file:///opt/devario/repo"
  mkdir -p "$staged_profile/airootfs/opt/devario/repo"
  cp -a -- "$staged_repo/." "$staged_profile/airootfs/opt/devario/repo/"
fi

# Use the Shelly binaries from the repository being installed into the image.
# The alternate-config marker proves this binary understands the isolated
# target RootDir and DBPath used by Devario's Archiso patch.
bsdtar -xf "${shelly_packages[0]}" -C "$shelly_root" \
  usr/bin/shelly usr/bin/shelly-key
devario_shelly="$shelly_root/usr/bin/shelly"
devario_shelly_key="$shelly_root/usr/bin/shelly-key"
if [[ ! -x "$devario_shelly" ]] \
  || ! grep -aFq 'SHELLY_ALPM_CONFIG' "$devario_shelly"; then
  echo "The repository Shelly binary lacks isolated ALPM config support." >&2
  exit 1
fi
if [[ ! -x "$devario_shelly_key" ]]; then
  echo "The repository Shelly package does not contain shelly-key." >&2
  exit 1
fi
if [[ ! -s /usr/share/pacman/keyrings/archlinux.gpg ]]; then
  echo "The Arch Linux keyring source is missing from the build environment." >&2
  exit 1
fi
if [[ ! -s "$devario_keyring_source/devario.gpg" \
  || ! -f "$devario_keyring_source/devario-trusted" \
  || ! -f "$devario_keyring_source/devario-revoked" ]]; then
  echo "The Devario keyring source is incomplete." >&2
  exit 1
fi

# Never depend on mutable host trust state and never create a private bootstrap
# key below airootfs. This per-build keyring is removed with the other temporary
# build state after mkarchiso finishes.
install -m 0644 /dev/null "$build_gpgdir/pubring.gpg"
install -m 0600 /dev/null "$build_gpgdir/secring.gpg"
"$devario_shelly_key" --init "$build_gpgdir"
"$devario_shelly_key" --gpgdir "$build_gpgdir" \
  --populate-from /usr/share/pacman/keyrings --populate archlinux
"$devario_shelly_key" --gpgdir "$build_gpgdir" \
  --populate-from "$devario_keyring_source" --populate devario
if [[ ! -s "$build_gpgdir/pubring.gpg" \
  || ! -s "$build_gpgdir/trustdb.gpg" \
  || -e "$build_gpgdir/pubring.kbx" ]]; then
  echo "The temporary build keyring is not in the libalpm-compatible format." >&2
  exit 1
fi

bsdtar -xf "$archiso_archive" -C "$archiso_source"
patched_archiso_dir="$archiso_source/archiso-v89"
if [[ ! -f "$patched_archiso_dir/archiso/mkarchiso" ]]; then
  echo "The bundled Archiso source has an unexpected layout." >&2
  exit 1
fi
patch --fuzz=0 -d "$patched_archiso_dir" -Np1 < "$archiso_patch"
patch --fuzz=0 -d "$patched_archiso_dir" -Np1 < "$archiso_late_overlay_patch"
patch --fuzz=0 -d "$patched_archiso_dir" -Np1 \
  < "$archiso_package_verification_patch"
patched_mkarchiso="$patched_archiso_dir/archiso/mkarchiso"
bash -O extglob -n "$patched_mkarchiso"

runtime_server_escaped="${runtime_server//\\/\\\\}"
runtime_server_escaped="${runtime_server_escaped//|/\\|}"
runtime_server_escaped="${runtime_server_escaped//&/\\&}"
sed \
  -e "s|@DEVARIO_RUNTIME_SIGLEVEL@|$runtime_siglevel|g" \
  -e "s|@DEVARIO_RUNTIME_REPO@|$runtime_server_escaped|g" \
  "$staged_profile/pacman.runtime.conf" \
  > "$staged_profile/airootfs/etc/pacman.conf"

sed "s|@DEVARIO_REPO@|$staged_repo|g" "$staged_profile/pacman.conf" > "$generated_conf"

gpgme_trace="$output_dir/devario-gpgme.log"
failure_report="$output_dir/devario-iso-failure-report.log"
install -m 0644 /dev/null "$gpgme_trace"
rm -f -- "$failure_report"

set +e
GPGME_DEBUG="9:$gpgme_trace" \
DEVARIO_SHELLY="$devario_shelly" \
DEVARIO_BUILD_GPGDIR="$build_gpgdir" \
DEVARIO_PACMAN_CONF="$generated_conf" \
DEVARIO_EDITION_ISO_NAME="$DEVARIO_EDITION_ISO_NAME" \
DEVARIO_EDITION_ISO_LABEL_PREFIX="$DEVARIO_EDITION_ISO_LABEL_PREFIX" \
DEVARIO_EDITION_ISO_PUBLISHER="$DEVARIO_EDITION_ISO_PUBLISHER" \
DEVARIO_EDITION_ISO_APPLICATION="$DEVARIO_EDITION_ISO_APPLICATION" \
  bash -O extglob "$patched_mkarchiso" \
    -v -r -w "$work_dir" -o "$output_dir" "$staged_profile"
archiso_status=$?
set -e

if (( archiso_status != 0 )); then
  {
    printf 'Archiso exit status: %s\n' "$archiso_status"
    printf 'Generated ALPM configuration: %s\n' "$generated_conf"
    printf 'Temporary GPG directory: %s\n\n' "$build_gpgdir"
    printf '%s\n' '--- Generated ALPM configuration ---'
    sed -n '1,240p' "$generated_conf"
    printf '%s\n' '--- Temporary keyring files ---'
    find "$build_gpgdir" -maxdepth 2 -printf '%M %u:%g %s %p\n' | sort
    printf '%s\n' '--- Temporary keyring public keys ---'
    gpg --homedir "$build_gpgdir" --batch --with-colons --list-keys
  } > "$failure_report" 2>&1
  chmod 0644 "$failure_report" "$gpgme_trace"
  echo "ISO failure report: $failure_report" >&2
  echo "GPGME verification trace: $gpgme_trace" >&2
  exit "$archiso_status"
fi

echo "ISO output is available in $output_dir"
