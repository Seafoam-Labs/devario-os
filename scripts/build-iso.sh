#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
profile_dir="$project_dir/iso"
edition_dir="$project_dir/editions/community"
core_repo_dir="${DEVARIO_CORE_REPO_DIR:-$project_dir/repo/core}"
managed_repo_dir="${DEVARIO_MANAGED_REPO_DIR:-}"
output_dir="${DEVARIO_OUTPUT_DIR:-$project_dir/out}"
work_dir="${DEVARIO_WORK_DIR:-$project_dir/work}"
core_runtime_url="${DEVARIO_CORE_REPO_URL:-${DEVARIO_REPO_URL:-https://repo.seafoam-labs.org/devario-core/x86_64}}"
managed_runtime_url="${DEVARIO_MANAGED_REPO_URL:-}"
core_keyring_source="${DEVARIO_CORE_KEYRING_DIR:-$project_dir/packages/devario-keyring}"
managed_keyring_source="${DEVARIO_MANAGED_KEYRING_DIR:-}"
release_build="${DEVARIO_RELEASE_BUILD:-0}"
release_version="${DEVARIO_RELEASE_VERSION:-}"
input_lock="${DEVARIO_INPUT_LOCK:-}"

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/build-iso.sh [--edition DIRECTORY]

Compose the base Devario ISO profile with Community by default, or with the strict
edition contract rooted at DIRECTORY, then build the resulting ISO.

Repository directories, keyring bundles, and credential-free HTTPS runtime
URLs are passed independently as DEVARIO_CORE_* and DEVARIO_MANAGED_* values.
Optional DEVARIO_LIVE_SIGNING_CERT and DEVARIO_LIVE_SIGNING_KEY sign netboot media.
Community rejects every managed input. Release builds require the authenticated
controlled nspawn/input-lock contract and fresh output/work directories.
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
  echo "devario-iso-builder must run as root. Use: sudo $0" >&2
  exit 1
fi

for build_command in awk bash bsdtar chmod cp find git gpg grep install ln mv patch readlink realpath sha256sum; do
  if ! command -v "$build_command" >/dev/null 2>&1; then
    echo "$build_command is required to prepare the Shelly-enabled Devario ISO builder." >&2
    exit 1
  fi
done

# shellcheck source=lib/python-env.sh
source "$script_dir/lib/python-env.sh"
devario_use_validation_python

python3 "$script_dir/run-iso-builder.py" --check

if [[ ! -f "$profile_dir/shelly.runtime.conf" ]]; then
  echo "The installed-system package-manager template is missing." >&2
  exit 1
fi

if [[ "$release_build" != 0 && "$release_build" != 1 ]]; then
  echo 'DEVARIO_RELEASE_BUILD must be 0 or 1.' >&2
  exit 2
fi
if (( release_build )); then
  [[ -n "$release_version" ]] || { echo 'Release ISO construction requires DEVARIO_RELEASE_VERSION.' >&2; exit 1; }
  devario_validate_release_version "$release_version"
  for fresh_dir in "$output_dir" "$work_dir"; do
    if [[ -e "$fresh_dir" ]] && [[ -n "$(find "$fresh_dir" -mindepth 1 -print -quit)" ]]; then
      echo "Release output/work directory must be fresh and empty: $fresh_dir" >&2
      exit 1
    fi
  done
  if [[ "${DEVARIO_CONTROLLED_NSPAWN:-0}" != 1 \
    || "$input_lock" != /input/CORE-INPUT-LOCK.json ]]; then
    echo 'Native or unauthenticated release ISO construction is forbidden.' >&2
    exit 1
  fi
  DEVARIO_REPOSITORY_NAME=devario-core "$script_dir/verify-controlled-builder.sh"
elif [[ -n "$release_version" ]]; then
  echo 'DEVARIO_RELEASE_VERSION is valid only for a controlled release ISO.' >&2
  exit 1
fi
mkdir -p "$output_dir" "$work_dir"

generated_conf="$(mktemp /tmp/devario-alpm.XXXXXX.conf)"
staged_core_repo="$(mktemp -d /tmp/devario-core-repo.XXXXXX)"
staged_managed_repo="$(mktemp -d /tmp/devario-managed-repo.XXXXXX)"
staged_profile="$(mktemp -d /tmp/devario-profile.XXXXXX)"
shelly_root="$(mktemp -d "$work_dir/.devario-shelly.XXXXXX")"
# gpg-agent creates Unix sockets beneath this directory. Timestamped run paths
# can exceed the socket path limit, so keep its private temporary home short.
build_gpgdir="$(mktemp -d /tmp/devario-keyring.XXXXXX)"
cleanup() {
  rm -f -- "$generated_conf"
  rm -rf -- "$staged_core_repo" "$staged_managed_repo"
  rm -rf -- "$staged_profile"
  rm -rf -- "$shelly_root"
  rm -rf -- "$build_gpgdir"
}
trap cleanup EXIT

# Stage the local repository under a short, root-readable path consumed by the
# isolated Shelly target transaction.
cp -a -- "$core_repo_dir/." "$staged_core_repo/"
chmod 755 "$staged_core_repo"
find "$staged_core_repo" -type f -exec chmod 444 {} +

devario_compose_profile \
  "$profile_dir" "$edition_dir" "$staged_profile" "$project_dir"
# This link targets files installed inside the image, not on the build host.
# Keep it out of the source archive consumed by GitHub's action downloader.
ln -sT -- /usr/share/calamares/qml "$staged_profile/airootfs/etc/calamares/qml"
echo "Building Devario $DEVARIO_EDITION_VARIANT edition ($DEVARIO_EDITION_ID)."

if (( release_build )); then
  "$script_dir/render-release-os-release.py" \
    --file "$staged_profile/airootfs/etc/os-release" \
    --edition "$DEVARIO_EDITION_ID" --variant "$DEVARIO_EDITION_VARIANT" \
    --release-version "$release_version"
fi

if (( DEVARIO_EDITION_HAS_MANAGED )); then
  if [[ -z "$managed_repo_dir" || -z "$managed_keyring_source" ]]; then
    echo 'An edition with managed package origins requires separate managed repository/keyring inputs.' >&2
    exit 1
  fi
  cp -a -- "$managed_repo_dir/." "$staged_managed_repo/"
  chmod 755 "$staged_managed_repo"
  find "$staged_managed_repo" -type f -exec chmod 444 {} +
else
  if [[ -n "$managed_repo_dir" || -n "$managed_keyring_source" || -n "$managed_runtime_url" ]]; then
    echo 'Community/core-only editions reject every managed repository, key, and URL input.' >&2
    exit 1
  fi
fi

key_policy=development
core_package_policy=local-installer
if (( release_build )); then key_policy=production; core_package_policy=strict; fi
devario_verify_repository "$staged_core_repo" devario-core "$core_keyring_source" "$key_policy" "$core_package_policy"
core_active="$DEVARIO_ACTIVE_SIGNER"; core_public="$DEVARIO_KEYRING_PUBLIC"
core_fingerprints=("${DEVARIO_PUBLIC_FINGERPRINTS[@]}")
if (( DEVARIO_EDITION_HAS_MANAGED )); then
  devario_verify_repository "$staged_managed_repo" devario-managed "$managed_keyring_source" "$key_policy"
  managed_active="$DEVARIO_ACTIVE_SIGNER"; managed_public="$DEVARIO_KEYRING_PUBLIC"
  managed_fingerprints=("${DEVARIO_PUBLIC_FINGERPRINTS[@]}")
  [[ "$core_active" != "$managed_active" ]] || { echo 'Core and managed active signers must be distinct.' >&2; exit 1; }
  devario_require_disjoint_fingerprint_sets core_fingerprints managed_fingerprints
fi

shopt -s nullglob
repo_packages=("$staged_core_repo"/*.pkg.tar.zst)
if (( ${#repo_packages[@]} == 0 )); then
  echo "The Devario repository contains no package archives." >&2
  exit 1
fi

# Shelly currently succeeds even when an explicitly requested package is not
# available. Verify every Devario-owned image package before starting the much
# more expensive Devario ISO transaction so a stale or incomplete local repository
# cannot produce a kernel-less target root.
required_devario_packages=(
  aqueous-core
  aqueous-integration-pearl
  aqueous-shell-pearl
  aqueous-session
  xdg-desktop-portal-aqueous
  calamares
  ckbcomp
  devario-desktop
  devario-base
  devario-filesystem
  devario-boot
  devario-dracut
  devario-keyring
  linux-devario
  linux-devario-headers
  pearl
  shelly
  shelly-cli
)
declare -A required_core_package_set=()
for package_name in "${required_devario_packages[@]}"; do
  required_core_package_set["$package_name"]=1
done
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
declare -A managed_package_counts=()
if (( DEVARIO_EDITION_HAS_MANAGED )); then
  managed_packages=("$staged_managed_repo"/*.pkg.tar.zst)
  (( ${#managed_packages[@]} > 0 )) || { echo 'Managed repository contains no packages.' >&2; exit 1; }
  for package_path in "${managed_packages[@]}"; do
    package_name="$(bsdtar -xOf "$package_path" .PKGINFO | awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
    [[ -n "$package_name" ]] || { echo "Unreadable managed package: $package_path" >&2; exit 1; }
    (( managed_package_counts["$package_name"] += 1 )) || true
  done
fi

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
  echo "Supply signed linux-devario, linux-devario-headers, and devario-dracut packages from the external package build." >&2
  exit 1
fi

# Enforce the edition's one-to-one package origin contract. An Arch-origin
# addition must not be shadowed by either Devario repository; core and managed
# additions must exist exactly once only in their declared authority.
for package_name in "${!DEVARIO_PACKAGE_ORIGINS[@]}"; do
  core_count="${repository_package_counts[$package_name]:-0}"
  managed_count="${managed_package_counts[$package_name]:-0}"
  case "${DEVARIO_PACKAGE_ORIGINS[$package_name]}" in
    arch)
      echo "Arch-origin edition packages require an explicit compatibility build: $package_name" >&2; exit 1
      ;;
    core)
      (( core_count == 1 && managed_count == 0 )) || { echo "Core package origin is missing/ambiguous: $package_name" >&2; exit 1; }
      ;;
    managed)
      (( core_count == 0 && managed_count == 1 )) || { echo "Managed package origin is missing/ambiguous: $package_name" >&2; exit 1; }
      ;;
  esac
done

# The fixed base profile has an implicit, code-owned origin contract: the
# required Devario package set comes only from core and every other base name
# resolves from core. This prevents the managed
# repository from shadowing an otherwise unlisted base package.
while IFS= read -r package_name || [[ -n "$package_name" ]]; do
  [[ "$package_name" =~ ^[[:space:]]*(#.*)?$ ]] && continue
  [[ -z "${DEVARIO_PACKAGE_ORIGINS[$package_name]:-}" ]] || continue
  core_count="${repository_package_counts[$package_name]:-0}"
  managed_count="${managed_package_counts[$package_name]:-0}"
  if [[ -n "${required_core_package_set[$package_name]:-}" ]]; then
    (( core_count == 1 && managed_count == 0 )) || {
      echo "Fixed core package origin is missing or shadowed: $package_name" >&2
      exit 1
    }
  elif (( managed_count != 0 || core_count != 1 )); then
    echo "Base package is missing or shadowed by Managed: $package_name" >&2
    exit 1
  fi
done < "$staged_profile/packages.x86_64"

qt_declarative_packages=("$staged_core_repo"/qt6-declarative-[0-9]*.pkg.tar.zst)
(( ${#qt_declarative_packages[@]} == 1 )) || { echo 'Expected exactly one qt6-declarative archive.' >&2; exit 1; }
bash "$script_dir/verify-qt-quick-package.sh" "${qt_declarative_packages[0]}"
calamares_packages=("$staged_core_repo"/calamares-[0-9]*.pkg.tar.zst)
(( ${#calamares_packages[@]} == 1 )) || { echo 'Expected exactly one Calamares archive.' >&2; exit 1; }
bash "$script_dir/verify-calamares-isa.sh" "${calamares_packages[0]}"

audit_args=(--database devario-core "$staged_core_repo/devario-core.db")
if (( DEVARIO_EDITION_HAS_MANAGED )); then
  audit_args+=(--database devario-managed "$staged_managed_repo/devario-managed.db")
fi
python3 "$script_dir/audit-iso-repositories.py" "${audit_args[@]}" \
  --packages "$staged_profile/packages.x86_64" --output "$work_dir/repository-audit.json"
python3 "$script_dir/audit-iso-package-paths.py" --files "$staged_core_repo/devario-core.files" \
  --dependency-audit "$work_dir/repository-audit.json" --output "$work_dir/core-path-audit.json"
if (( DEVARIO_EDITION_HAS_MANAGED )); then
  python3 "$script_dir/audit-iso-package-paths.py" --files "$staged_managed_repo/devario-managed.files" \
    --dependency-audit "$work_dir/repository-audit.json" --output "$work_dir/managed-path-audit.json"
fi

shelly_packages=("$staged_core_repo"/shelly-cli-[0-9]*.pkg.tar.zst)
if (( ${#shelly_packages[@]} != 1 )); then
  echo "The Devario repository must contain exactly one Shelly CLI package." >&2
  exit 1
fi

if (( release_build )); then
  [[ -n "$core_runtime_url" ]] || { echo 'Release image requires DEVARIO_CORE_REPO_URL.' >&2; exit 1; }
  devario_validate_https_url "$core_runtime_url"
  if (( DEVARIO_EDITION_HAS_MANAGED )); then
    [[ -n "$managed_runtime_url" ]] || { echo 'Managed release requires DEVARIO_MANAGED_REPO_URL.' >&2; exit 1; }
    devario_validate_https_url "$managed_runtime_url"
  fi

  keyring_packages=("$staged_core_repo"/devario-keyring-[0-9]*.pkg.tar.zst)
  (( ${#keyring_packages[@]} == 1 )) || { echo 'Core release requires exactly one keyring package.' >&2; exit 1; }
  devario_verify_keyring_package "${keyring_packages[0]}" "$core_keyring_source" devario-core
  if (( DEVARIO_EDITION_HAS_MANAGED )); then
    managed_keyring_packages=("$staged_managed_repo"/devario-managed-keyring-[0-9]*.pkg.tar.zst)
    (( ${#managed_keyring_packages[@]} == 1 )) || { echo 'Managed release requires exactly one managed keyring package.' >&2; exit 1; }
    devario_verify_keyring_package "${managed_keyring_packages[0]}" "$managed_keyring_source" devario-managed
  fi
  core_runtime_siglevel=Required
  core_runtime_server="$core_runtime_url"
  managed_runtime_siglevel=Required
  managed_runtime_server="$managed_runtime_url"
else
  core_runtime_siglevel=Required
  core_runtime_server="$core_runtime_url"
  managed_runtime_siglevel=Required
  managed_runtime_server="$managed_runtime_url"
fi

# The CLI split package owns both executables. The assembler passes its isolated
# transaction configuration explicitly with --config.
bsdtar -xf "${shelly_packages[0]}" -C "$shelly_root" \
  usr/bin/shelly usr/bin/shelly-key
devario_shelly="$shelly_root/usr/bin/shelly"
devario_shelly_key="$shelly_root/usr/bin/shelly-key"
if [[ ! -x "$devario_shelly" || ! -x "$devario_shelly_key" ]]; then
  echo "The repository Shelly CLI package must contain shelly and shelly-key." >&2
  exit 1
fi
"$devario_shelly" list standard --help >/dev/null
key_help="$("$devario_shelly_key" --help)"
if [[ "$key_help" != *'/usr/share/shelly/keyrings'* ]]; then
  echo 'The staged shelly-cli package predates the Devario public-key directory patch. Rebuild Shelly with -Dpath-profile=devario.' >&2
  exit 1
fi
devario_validate_keyring_bundle "$core_keyring_source" devario-core "$key_policy"
if (( DEVARIO_EDITION_HAS_MANAGED )); then
  devario_validate_keyring_bundle "$managed_keyring_source" devario-managed "$key_policy"
fi

# Never depend on mutable host trust state and never create a private bootstrap
# key below airootfs. This per-build keyring is removed with the other temporary
# build state after devario-iso-builder finishes.
install -m 0644 /dev/null "$build_gpgdir/pubring.gpg"
install -m 0600 /dev/null "$build_gpgdir/secring.gpg"
"$devario_shelly_key" --init "$build_gpgdir"
"$devario_shelly_key" --gpgdir "$build_gpgdir" \
  --populate-from "$core_keyring_source" --populate devario
if (( DEVARIO_EDITION_HAS_MANAGED )); then
  "$devario_shelly_key" --gpgdir "$build_gpgdir" \
    --populate-from "$managed_keyring_source" --populate devario-managed
fi
if [[ ! -s "$build_gpgdir/pubring.gpg" \
  || ! -s "$build_gpgdir/trustdb.gpg" \
  || -e "$build_gpgdir/pubring.kbx" ]]; then
  echo "The temporary build keyring is not in the libalpm-compatible format." >&2
  exit 1
fi

escape_sed() {
  local value="$1"
  value="${value//\\/\\\\}"; value="${value//|/\\|}"; value="${value//&/\\&}"
  printf '%s\n' "$value"
}
core_runtime_server_escaped="$(escape_sed "$core_runtime_server")"
managed_runtime_repository=''
managed_build_repository=''
if (( DEVARIO_EDITION_HAS_MANAGED )); then
  managed_runtime_server_escaped="$(escape_sed "$managed_runtime_server")"
  managed_runtime_repository="[devario-managed]\nSigLevel = $managed_runtime_siglevel\nServer = $managed_runtime_server_escaped"
  managed_build_repository="[devario-managed]\nSigLevel = Never\nServer = file://$(escape_sed "$staged_managed_repo")"
fi
sed \
  -e "s|@DEVARIO_CORE_RUNTIME_SIGLEVEL@|$core_runtime_siglevel|g" \
  -e "s|@DEVARIO_CORE_RUNTIME_REPO@|$core_runtime_server_escaped|g" \
  -e "s|@DEVARIO_MANAGED_RUNTIME_REPOSITORY@|$managed_runtime_repository|g" \
  "$staged_profile/shelly.runtime.conf" \
  > "$staged_profile/airootfs/etc/shelly.conf"

sed \
  -e "s|@DEVARIO_CORE_REPO@|$(escape_sed "$staged_core_repo")|g" \
  -e "s|@DEVARIO_MANAGED_BUILD_REPOSITORY@|$managed_build_repository|g" \
  "$staged_profile/shelly.build.conf" > "$generated_conf"

if (( release_build )); then
  build_record_dir="$staged_profile/airootfs/usr/share/devario"
  install -d -m 0755 "$build_record_dir"
  BUILD_RECORD="$build_record_dir/build-source.json" INPUT_LOCK="$input_lock" \
  EDITION="$DEVARIO_EDITION_ID" RELEASE_VERSION="$release_version" \
  CORE_URL="$core_runtime_url" CORE_ACTIVE="$core_active" \
  CORE_PUBLIC="$core_public" MANAGED_URL="$managed_runtime_url" \
  MANAGED_ACTIVE="${managed_active:-}" MANAGED_PUBLIC="${managed_public:-}" \
  SCHEMA="$script_dir/schemas/image-build-record.schema.json" python3 - <<'PY'
import hashlib,json,os,pathlib
from jsonschema import Draft202012Validator
def hook(pairs):
 out={}
 for k,v in pairs:
  if k in out: raise SystemExit(f"duplicate JSON key: {k}")
  out[k]=v
 return out
raw=pathlib.Path(os.environ["INPUT_LOCK"]).read_bytes(); lock=json.loads(raw,object_pairs_hook=hook)
if raw!=(json.dumps(lock,sort_keys=True,separators=(",",":"))+"\n").encode(): raise SystemExit("input lock is not canonical")
if lock["releaseVersion"] != os.environ["RELEASE_VERSION"]: raise SystemExit("release version differs from input lock")
data={"schemaVersion":2,"isoBuilder":lock["isoBuilder"],"releaseMode":True,"edition":os.environ["EDITION"],"releaseVersion":lock["releaseVersion"],"coreCommit":lock["core"]["commit"],
 "sourceDateEpoch":lock["sourceDateEpoch"],"inputLockSha256":hashlib.sha256(raw).hexdigest(),
 "coreRepository":{"url":os.environ["CORE_URL"],"activeSigner":os.environ["CORE_ACTIVE"],"publicKeyringSha256":hashlib.sha256(pathlib.Path(os.environ["CORE_PUBLIC"]).read_bytes()).hexdigest()}}
if os.environ["EDITION"]=="managed":
 data["managedCommit"]=lock["edition"]["commit"]
 data["managedRepository"]={"url":os.environ["MANAGED_URL"],"activeSigner":os.environ["MANAGED_ACTIVE"],"publicKeyringSha256":hashlib.sha256(pathlib.Path(os.environ["MANAGED_PUBLIC"]).read_bytes()).hexdigest()}
schema=json.loads(pathlib.Path(os.environ["SCHEMA"]).read_text(),object_pairs_hook=hook); Draft202012Validator(schema).validate(data)
pathlib.Path(os.environ["BUILD_RECORD"]).write_text(json.dumps(data,sort_keys=True,separators=(",",":"))+"\n")
PY
  chmod 0444 "$build_record_dir/build-source.json"
fi

gpgme_trace="$output_dir/devario-gpgme.log"
failure_report="$output_dir/devario-iso-failure-report.log"
assembler_log="$output_dir/devario-iso-assembler.log"
install -m 0644 /dev/null "$gpgme_trace"
rm -f -- "$failure_report"

set +e
GPGME_DEBUG="9:$gpgme_trace" \
DEVARIO_EDITION_ISO_NAME="$DEVARIO_EDITION_ISO_NAME" \
DEVARIO_EDITION_ISO_LABEL_PREFIX="$DEVARIO_EDITION_ISO_LABEL_PREFIX" \
DEVARIO_EDITION_ISO_PUBLISHER="$DEVARIO_EDITION_ISO_PUBLISHER" \
DEVARIO_EDITION_ISO_APPLICATION="$DEVARIO_EDITION_ISO_APPLICATION" \
  python3 "$script_dir/run-iso-builder.py" \
    --profile "$staged_profile" --work "$work_dir" --output "$output_dir" \
    --shelly "$devario_shelly" --config "$generated_conf" --keyring "$build_gpgdir" \
    2>&1 | tee "$assembler_log"
builder_status=${PIPESTATUS[0]}
set -e

if (( builder_status != 0 )); then
  {
    printf 'Devario ISO exit status: %s\n' "$builder_status"
    printf 'Generated ALPM configuration: %s\n' "$generated_conf"
    printf 'Temporary GPG directory: %s\n\n' "$build_gpgdir"
    printf '%s\n' '--- Image assembler output (last 200 lines) ---'
    tail -n 200 "$assembler_log"
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
  exit "$builder_status"
fi

if (( release_build )); then
  mapfile -t built_images < <(find "$output_dir" -maxdepth 1 -type f -name '*.iso' -print)
  (( ${#built_images[@]} == 1 )) || { echo 'Release build must produce exactly one ISO.' >&2; exit 1; }
  boundary_args=(
    --iso "${built_images[0]}" --edition "$DEVARIO_EDITION_ID" --release
    --input-lock "$input_lock" --core-keyring "$core_keyring_source"
    --core-url "$core_runtime_url" --release-version "$release_version"
    --write-inventory "$output_dir/IMAGE-PACKAGE-INVENTORY.json"
  )
  if (( DEVARIO_EDITION_HAS_MANAGED )); then
    boundary_args+=(--managed-keyring "$managed_keyring_source" --managed-url "$managed_runtime_url")
  fi
  if [[ -n "${DEVARIO_EXPECTED_IMAGE_INVENTORY:-}" ]]; then
    boundary_args+=(--expected-inventory "$DEVARIO_EXPECTED_IMAGE_INVENTORY")
  fi
  "$script_dir/verify-image-boundary.sh" "${boundary_args[@]}"
fi

echo "ISO output is available in $output_dir"
