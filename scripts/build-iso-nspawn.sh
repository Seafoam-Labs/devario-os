#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
container_root="${DEVARIO_NSPAWN_ROOT:-/var/lib/machines/devario-builder}"
container_project_dir="/build"
edition_dir="$project_dir/editions/community"
release_version=''

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/build-iso-nspawn.sh [--edition DIRECTORY] [--release-version VERSION]

Prepare or reuse the Devario systemd-nspawn builder and create an ISO from the
core packages in repo/core/. The resulting image is written to out/ by default.
An edition directory outside devario-os is mounted read-only in the builder.

Environment:
  DEVARIO_NSPAWN_ROOT   Container root (default: /var/lib/machines/devario-builder)
  DEVARIO_NSPAWN_WORK_DIR
                         Work directory inside the container (default: a fresh
                         directory below /var/tmp)
  DEVARIO_CORE_REPO_DIR Core repository directory (default: repo/core)
  DEVARIO_CORE_KEYRING_DIR
                         Core public-key bundle (default: packages/devario-keyring)
  DEVARIO_CORE_REPO_URL Credential-free HTTPS core runtime repository URL
  DEVARIO_MANAGED_REPO_DIR / DEVARIO_MANAGED_KEYRING_DIR / DEVARIO_MANAGED_REPO_URL
                         Distinct inputs required by a managed edition
  DEVARIO_OUTPUT_DIR    Host ISO output directory (default: project out/)
  DEVARIO_LIVE_SIGNING_CERT / DEVARIO_LIVE_SIGNING_KEY
                         Optional CMS inputs for development netboot media

Release mode additionally requires --release-version. Development builds reject
that option and retain their explicit Development identity.

The bootstrap-related environment accepted by build-packages-nspawn.sh is also
honored when the container must be prepared for the first time.
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
    --release-version)
      if (( $# < 2 )); then echo '--release-version requires a value.' >&2; exit 2; fi
      release_version="$2"
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
if ! host_edition_dir="$(realpath -e -- "$edition_dir")" \
  || [[ ! -d "$host_edition_dir" ]]; then
  echo "Edition directory does not exist: $edition_dir" >&2
  exit 1
fi
if [[ "$host_edition_dir" == *:* || "$host_edition_dir" == *$'\n'* ]]; then
  echo 'The nspawn wrapper cannot map an edition path containing a colon or newline.' >&2
  exit 1
fi

if [[ "${DEVARIO_RELEASE_BUILD:-0}" == 1 ]]; then
  [[ -n "$release_version" ]] || { echo 'Release builds require --release-version.' >&2; exit 2; }
  exec "$script_dir/build-iso-controlled-nspawn.sh" --edition "$host_edition_dir" \
    --release-version "$release_version"
fi
if [[ -n "$release_version" ]]; then
  echo '--release-version is accepted only when DEVARIO_RELEASE_BUILD=1.' >&2
  exit 2
fi

if (( EUID != 0 )); then
  echo "Run this script through sudo so Archiso can mount its target filesystems." >&2
  exit 1
fi
if [[ "$container_root" != /* ]]; then
  echo "DEVARIO_NSPAWN_ROOT must be an absolute path." >&2
  exit 1
fi
if [[ -n "${DEVARIO_WORK_DIR:-}" ]]; then
  echo "DEVARIO_WORK_DIR cannot be host-bound by the nspawn wrapper." >&2
  echo "Use DEVARIO_NSPAWN_WORK_DIR with an internal path such as /var/tmp/devario-work." >&2
  exit 1
fi

for command_name in install realpath systemd-nspawn tail tee; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required host command: $command_name" >&2
    exit 1
  fi
done
if [[ ! -x "$script_dir/build-packages-nspawn.sh" ]]; then
  echo "The nspawn builder preparation script is missing or not executable." >&2
  exit 1
fi
if [[ ! -x "$script_dir/build-iso.sh" ]]; then
  echo "The underlying ISO build script is missing or not executable." >&2
  exit 1
fi
requested_core_repo="${DEVARIO_CORE_REPO_DIR:-$project_dir/repo/core}"
if [[ "$requested_core_repo" != /* ]]; then requested_core_repo="$project_dir/$requested_core_repo"; fi
host_core_repo_dir="$(realpath -e -- "$requested_core_repo")"
if [[ ! -f "$host_core_repo_dir/devario-core.db.tar.zst" ]]; then
  echo "The local repository is missing. Build packages before creating the ISO." >&2
  exit 1
fi
requested_core_keyring="${DEVARIO_CORE_KEYRING_DIR:-$project_dir/packages/devario-keyring}"
if [[ "$requested_core_keyring" != /* ]]; then requested_core_keyring="$project_dir/$requested_core_keyring"; fi
host_core_keyring_dir="$(realpath -e -- "$requested_core_keyring")"

echo "Preparing the reusable baseline nspawn environment..."
"$script_dir/build-packages-nspawn.sh" --prepare-only

run_container_root() {
  systemd-nspawn \
    --quiet \
    --register=no \
    --console=pipe \
    --resolv-conf=replace-host \
    --directory="$container_root" \
    "$@"
}

echo "Installing the Archiso toolchain through Shelly..."
run_container_root /usr/bin/shelly sync standard --no-confirm
run_container_root /usr/bin/shelly install standard --no-confirm \
  archiso limine

if [[ -n "${DEVARIO_NSPAWN_WORK_DIR:-}" ]]; then
  container_work_dir="$DEVARIO_NSPAWN_WORK_DIR"
  if [[ "$container_work_dir" != /* \
    || "$container_work_dir" == "$container_project_dir" \
    || "$container_work_dir" == "$container_project_dir/"* ]]; then
    echo "DEVARIO_NSPAWN_WORK_DIR must be an absolute container-internal path outside /build." >&2
    exit 1
  fi
  run_container_root /usr/bin/install -d -m 0755 "$container_work_dir"
else
  container_work_dir="$(
    run_container_root /usr/bin/mktemp -d /var/tmp/devario-archiso.XXXXXX
  )"
fi
echo "Using container-internal Archiso work directory: $container_work_dir"

resolve_host_path() {
  local requested_path="$1"
  if [[ "$requested_path" == /* ]]; then
    realpath -m -- "$requested_path"
  else
    realpath -m -- "$project_dir/$requested_path"
  fi
}

host_output_dir="$(resolve_host_path "${DEVARIO_OUTPUT_DIR:-out}")"
install -d -m 0755 "$host_output_dir"
build_log="$host_output_dir/devario-iso-build.log"

nspawn_args=(
  --quiet
  --register=no
  --console=pipe
  --resolv-conf=replace-host
  --capability=CAP_SYS_ADMIN,CAP_MKNOD
  --directory="$container_root"
  --bind="$project_dir:$container_project_dir"
  --chdir="$container_project_dir"
)

map_host_path() {
  local host_path="$1"
  local external_container_path="$2"

  if [[ "$host_path" == "$project_dir" ]]; then
    mapped_container_path="$container_project_dir"
  elif [[ "$host_path" == "$project_dir/"* ]]; then
    mapped_container_path="$container_project_dir/${host_path#"$project_dir/"}"
  else
    mapped_container_path="$external_container_path"
    nspawn_args+=(--bind="$host_path:$mapped_container_path")
  fi
}

map_host_path "$host_output_dir" /devario-output
container_output_dir="$mapped_container_path"

if [[ "$host_edition_dir" == "$project_dir" ]]; then
  container_edition_dir="$container_project_dir"
elif [[ "$host_edition_dir" == "$project_dir/"* ]]; then
  container_edition_dir="$container_project_dir/${host_edition_dir#"$project_dir/"}"
else
  container_edition_dir=/devario-edition
  nspawn_args+=(--bind-ro="$host_edition_dir:$container_edition_dir")
fi

map_readonly_input() {
  local host_path="$1"
  local external_container_path="$2"
  if [[ ! -d "$host_path" || -L "$host_path" \
    || "$host_path" == *:* || "$host_path" == *$'\n'* ]]; then
    echo "Repository/keyring input is unavailable or unsafe: $host_path" >&2
    exit 1
  fi
  if [[ "$host_path" == "$project_dir" ]]; then
    mapped_input_path="$container_project_dir"
  elif [[ "$host_path" == "$project_dir/"* ]]; then
    mapped_input_path="$container_project_dir/${host_path#"$project_dir/"}"
  else
    mapped_input_path="$external_container_path"
    nspawn_args+=(--bind-ro="$host_path:$mapped_input_path")
  fi
}

map_readonly_input "$host_core_repo_dir" /devario-core-repo
container_core_repo_dir="$mapped_input_path"
map_readonly_input "$host_core_keyring_dir" /devario-core-keyring
container_core_keyring_dir="$mapped_input_path"
nspawn_args+=(
  --setenv="DEVARIO_CORE_REPO_DIR=$container_core_repo_dir"
  --setenv="DEVARIO_CORE_KEYRING_DIR=$container_core_keyring_dir"
)
if [[ -n "${DEVARIO_MANAGED_REPO_DIR:-}" || -n "${DEVARIO_MANAGED_KEYRING_DIR:-}" ]]; then
  [[ -n "${DEVARIO_MANAGED_REPO_DIR:-}" && -n "${DEVARIO_MANAGED_KEYRING_DIR:-}" ]] || {
    echo 'Managed repository and keyring inputs must be supplied together.' >&2
    exit 1
  }
  requested_managed_repo="$DEVARIO_MANAGED_REPO_DIR"
  requested_managed_keyring="$DEVARIO_MANAGED_KEYRING_DIR"
  if [[ "$requested_managed_repo" != /* ]]; then requested_managed_repo="$project_dir/$requested_managed_repo"; fi
  if [[ "$requested_managed_keyring" != /* ]]; then requested_managed_keyring="$project_dir/$requested_managed_keyring"; fi
  host_managed_repo_dir="$(realpath -e -- "$requested_managed_repo")"
  host_managed_keyring_dir="$(realpath -e -- "$requested_managed_keyring")"
  map_readonly_input "$host_managed_repo_dir" /devario-managed-repo
  container_managed_repo_dir="$mapped_input_path"
  map_readonly_input "$host_managed_keyring_dir" /devario-managed-keyring
  container_managed_keyring_dir="$mapped_input_path"
  nspawn_args+=(
    --setenv="DEVARIO_MANAGED_REPO_DIR=$container_managed_repo_dir"
    --setenv="DEVARIO_MANAGED_KEYRING_DIR=$container_managed_keyring_dir"
  )
fi

nspawn_args+=(
  --setenv="DEVARIO_OUTPUT_DIR=$container_output_dir"
  --setenv="DEVARIO_WORK_DIR=$container_work_dir"
)
if [[ -n "${DEVARIO_LIVE_SIGNING_CERT:-}" || -n "${DEVARIO_LIVE_SIGNING_KEY:-}" ]]; then
  for signing_kind in CERT KEY; do
    signing_variable="DEVARIO_LIVE_SIGNING_$signing_kind"
    signing_path="${!signing_variable:-}"
    [[ -f "$signing_path" && "$signing_path" != *:* && ! "$signing_path" =~ [[:space:]] ]] || {
      echo 'Both live signing certificate and key paths must be supplied.' >&2
      exit 1
    }
    signing_path="$(realpath -e -- "$signing_path")"
    nspawn_args+=(--bind-ro="$signing_path:/run/devario-live-signing-$signing_kind")
    nspawn_args+=(--setenv="$signing_variable=/run/devario-live-signing-$signing_kind")
  done
fi
if [[ -n "${DEVARIO_CORE_REPO_URL:-${DEVARIO_REPO_URL:-}}" ]]; then
  nspawn_args+=(--setenv="DEVARIO_CORE_REPO_URL=${DEVARIO_CORE_REPO_URL:-$DEVARIO_REPO_URL}")
fi
if [[ -n "${DEVARIO_MANAGED_REPO_URL:-}" ]]; then
  nspawn_args+=(--setenv="DEVARIO_MANAGED_REPO_URL=$DEVARIO_MANAGED_REPO_URL")
fi

echo "Building the Devario ISO inside the nspawn environment..."
set +e
systemd-nspawn "${nspawn_args[@]}" \
  /usr/bin/env -u LD_PRELOAD \
  ./scripts/build-iso.sh --edition "$container_edition_dir" 2>&1 | tee "$build_log"
build_pipeline_status=("${PIPESTATUS[@]}")
set -e
chmod 0644 "$build_log"

if (( build_pipeline_status[1] != 0 )); then
  echo "Unable to write the ISO build log to $build_log" >&2
  exit "${build_pipeline_status[1]}"
fi
if (( build_pipeline_status[0] != 0 )); then
  echo >&2
  echo "ISO construction failed. The complete log is at: $build_log" >&2
  echo "The final 200 log lines follow:" >&2
  tail -n 200 "$build_log" >&2
  exit "${build_pipeline_status[0]}"
fi

echo "ISO output is available in $host_output_dir"
echo "ISO build log is available at $build_log"
