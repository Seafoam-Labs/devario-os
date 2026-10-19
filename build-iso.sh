#!/usr/bin/env bash
# Build a local Community ISO using the canonical devario-os pipeline.
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
os_dir="${DEVARIO_OS_DIR:-$script_dir}"
repo_source=
installer_dir=
run_dir=
download_cache=
repo_url=https://mirrors.seafoam-labs.org/devario-core/x86_64
jobs=6
install_dependencies=1
dry_run=0
step=preflight
sudo_keepalive_pid=

usage() {
  cat <<'EOF'
Usage: ./build-iso.sh [OPTIONS]

Run as your normal user on an x86_64 Arch/Devario build host with Shelly
configured. Uses Shelly's RLPM backend for package operations. Local packages
build in a fresh container using verified Devario tools and dependencies.

  --os-dir DIRECTORY        Override this checkout (also DEVARIO_OS_DIR)
  --repo-dir DIRECTORY      Copy an existing combined snapshot instead of downloading
  --repo-url URL            HTTPS download and installed-system repository URL
  --installer-dir DIRECTORY Use six prebuilt local installer archives
  --run-dir DIRECTORY       New, nonexistent directory for all build results
  --download-cache DIR      Reusable signed-package download cache
  --jobs NUMBER             Parallel downloads, 1-16 (default: 6)
  --skip-deps               Check host tools without installing/upgrading them
  --dry-run                 Print the workflow without changes or downloads
  -h, --help                Show this help

Default: install host tools through Shelly, prepare Python validation, validate
sources, resolve/verify all configured repositories, build the six local installer packages,
audit the completed repository, assemble the ISO, and verify its SHA-256.
Kernel, desktop, Shelly, and other runtime packages come from signed binaries.
Local recipes are built from devario-os/packages, not devario-installer copies.
Sudo authenticates once before host setup; credentials are refreshed until exit.

Results: devario-os/work/iso-runs/<unique-run>/out/*.iso, with checksums,
assembler reports, build.log, and retained package/image work for diagnostics.
Every retry creates a fresh run; the download cache is reused. This is the
local Community workflow; controlled releases use devario-os release tooling.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
while (( $# )); do
  case "$1" in
    --os-dir|--repo-dir|--repo-url|--installer-dir|--run-dir|--download-cache|--jobs)
      (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || die "$1 needs a value."
      case "$1" in
        --os-dir) os_dir="$2" ;;
        --repo-dir) repo_source="$2" ;;
        --repo-url) repo_url="$2" ;;
        --installer-dir) installer_dir="$2" ;;
        --run-dir) run_dir="$2" ;;
        --download-cache) download_cache="$2" ;;
        --jobs) jobs="$2" ;;
      esac
      shift 2 ;;
    --skip-deps) install_dependencies=0; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)." ;;
  esac
done

[[ "$jobs" =~ ^([1-9]|1[0-6])$ ]] || die '--jobs must be between 1 and 16.'
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || die 'An x86_64 Linux build host is required.'
(( EUID != 0 )) || die 'Run without sudo so package builds remain unprivileged; assembly requests sudo itself.'
[[ "${DEVARIO_RELEASE_BUILD:-0}" == 0 && -z "${DEVARIO_RELEASE_VERSION:-}" &&
   "${DEVARIO_CONTROLLED_NSPAWN:-0}" == 0 ]] || die 'Use the controlled release scripts for release builds.'
for variable in DEVARIO_MANAGED_REPO_DIR DEVARIO_MANAGED_REPO_URL DEVARIO_MANAGED_KEYRING_DIR; do
  [[ -z "${!variable:-}" ]] || die "$variable is incompatible with the Community workflow."
done

[[ -n "$os_dir" && -d "$os_dir" ]] || die 'Cannot locate devario-os; pass --os-dir DIRECTORY.'
os_dir="$(realpath -e -- "$os_dir")"
for helper in build-iso.sh build-packages-core.py stage-iso-repositories.py stage-installer-packages.sh \
  validate.sh with-validation-env.sh prepare-validation-env.py audit-iso-repositories.py \
  audit-iso-package-paths.py lib/repository.sh; do
  [[ -r "$os_dir/scripts/$helper" ]] || die "Missing devario-os helper: scripts/$helper"
done
keyring_dir="$os_dir/packages/devario-keyring"
[[ -d "$keyring_dir" ]] || die "Missing keyring bundle: $keyring_dir"
if [[ -n "$repo_source" ]]; then
  repo_source="$(realpath -e -- "$repo_source")"
  [[ -d "$repo_source" ]] || die '--repo-dir must be a directory.'
fi
if [[ -n "$installer_dir" ]]; then
  installer_dir="$(realpath -e -- "$installer_dir")"
  [[ -d "$installer_dir" ]] || die '--installer-dir must be a directory.'
fi
run_dir="$(realpath -m -- "${run_dir:-$os_dir/work/iso-runs/$(date -u +%Y%m%dT%H%M%SZ)-$$}")"
download_cache="$(realpath -m -- "${download_cache:-$os_dir/work/repository-downloads}")"
[[ "$run_dir" != / && ! "$run_dir" =~ [[:space:]] ]] || die 'The ISO assembler needs a run path without whitespace, other than /.'
[[ ! -e "$run_dir" && ! -L "$run_dir" ]] || die "Run directory already exists; choose a fresh one: $run_dir"
# Avoid recursive copies and preserve the reusable cache independently of runs.
for input_dir in "$repo_source" "$installer_dir" "$download_cache" "$os_dir/iso" "$os_dir/packages"; do
  [[ -n "$input_dir" ]] || continue
  if [[ "$run_dir/" == "$input_dir/"* || "$input_dir/" == "$run_dir/"* ]]; then
    die "Run directory must be separate from input/cache tree: $input_dir"
  fi
done

run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if (( ! dry_run )); then "$@"; fi
}
phase() { step="$1"; printf '\n==> %s\n' "$step"; }
finish() {
  local status=$?
  trap - EXIT
  if [[ -n "$sudo_keepalive_pid" ]]; then
    kill "$sudo_keepalive_pid" 2>/dev/null || true
    wait "$sudo_keepalive_pid" 2>/dev/null || true
  fi
  if (( status != 0 )); then
    printf '\nBuild failed during %s (exit %s).\nLog: %s/build.log\nRetained run: %s\n' \
      "$step" "$status" "$run_dir" "$run_dir" >&2
  fi
  exit "$status"
}

keep_sudo_alive() {
  # $$ remains the orchestrator PID in this background subshell. Reap the
  # timer too, so it cannot retain build.log's pipe after the build exits.
  timer_pid=
  trap 'if [[ -n "$timer_pid" ]]; then kill "$timer_pid" 2>/dev/null || true; wait "$timer_pid" 2>/dev/null || true; fi' EXIT
  trap 'exit 0' INT TERM
  while kill -0 "$$" 2>/dev/null; do
    if ! sudo -n -v; then
      printf '\nSudo credential refresh failed; stopping the build without another password prompt.\n' >&2
      kill -TERM "$$" 2>/dev/null || true
      exit 1
    fi
    sleep 30 &
    timer_pid=$!
    wait "$timer_pid" || exit
    timer_pid=
  done
}

if (( ! dry_run )); then
  command -v sudo >/dev/null || die 'sudo is required for ISO assembly.'
  command -v shelly >/dev/null || die 'Install and configure a trusted Shelly bootstrap before running this script.'
  mkdir -p -- "$(dirname -- "$run_dir")"
  mkdir -- "$run_dir"
  exec > >(tee "$run_dir/build.log") 2>&1
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
fi
printf 'OS checkout: %s\nRun directory: %s\n' "$os_dir" "$run_dir"
repo_dir="$run_dir/core"
output_dir="$run_dir/out"
validation_cache="${DEVARIO_VALIDATION_CACHE:-$os_dir/work/validation-python}"
export DEVARIO_VALIDATION_CACHE="$(realpath -m -- "$validation_cache")"

phase 'Select the RLPM package backend'
# Keep other Shelly settings, but make the backend choice private to this run.
# XDG paths must be absolute; Shelly falls back to ~/.config otherwise.
original_config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
[[ "$original_config_home" == /* ]] || original_config_home="$HOME/.config"
rlpm_config_home="$run_dir/shelly-config"
run mkdir -p -- "$rlpm_config_home/shelly"
for config_file in config.json shellybuild.conf; do
  if [[ -f "$original_config_home/shelly/$config_file" ]]; then
    run cp -- "$original_config_home/shelly/$config_file" "$rlpm_config_home/shelly/$config_file"
  fi
done
export XDG_CONFIG_HOME="$rlpm_config_home"
run shelly config set NativePackageBackend rlpm
if (( ! dry_run )); then
  selected_backend="$(shelly config get NativePackageBackend)"
  [[ "$selected_backend" == rlpm ]] || die "Shelly did not select RLPM: $selected_backend"
  # Shelly re-execs itself through SHELLY_ELEVATOR for host transactions. sudo
  # normally drops XDG_CONFIG_HOME, so restore it explicitly in that child too.
  cat > "$run_dir/rlpm-elevate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
run_dir="$(dirname -- "$(realpath -e -- "${BASH_SOURCE[0]}")")"
exec sudo -n -- env XDG_CONFIG_HOME="$run_dir/shelly-config" "$@"
EOF
  chmod 755 "$run_dir/rlpm-elevate"
else
  printf '+ create %s/rlpm-elevate to preserve the RLPM configuration through sudo\n' "$run_dir"
fi
export SHELLY_ELEVATOR="$run_dir/rlpm-elevate"

phase 'Authenticate administrator access'
run sudo -v
if (( ! dry_run )); then
  keep_sudo_alive &
  sudo_keepalive_pid=$!
else
  printf '+ keep sudo credentials valid every 30 seconds until the build exits\n'
fi
export DEVARIO_SUDO_NONINTERACTIVE=1

phase 'Prepare host tools'
if (( install_dependencies )); then
  run shelly install standard --needed --no-confirm python libisoburn dosfstools mtools \
    squashfs-tools openssl util-linux systemd git libarchive gnupg binutils zstd patch
fi
if (( ! dry_run )); then
  for tool in python3 bsdtar gpg gpgv git patch awk find sha256sum \
    xorriso mkfs.fat mcopy mksquashfs openssl unshare mount umount chroot flock readelf; do
    command -v "$tool" >/dev/null || die "Missing host tool: $tool (rerun without --skip-deps)."
  done
  if [[ -z "$installer_dir" ]]; then
    command -v systemd-nspawn >/dev/null || die 'systemd-nspawn is required to build installer packages.'
  fi
fi
phase 'Prepare pinned Python validation tools and validate sources'
run python3 "$os_dir/scripts/prepare-validation-env.py"
run bash "$os_dir/scripts/validate.sh"
# Validate the runtime URL even when an existing snapshot was selected.
run bash "$os_dir/scripts/with-validation-env.sh" bash -euc \
  'source "$1"; devario_validate_https_url "$2"' iso-url "$os_dir/scripts/lib/repository.sh" "$repo_url"

verify_repository() {
  run bash "$os_dir/scripts/with-validation-env.sh" bash -euc \
    'source "$1"; devario_verify_repository "$2" devario-core "$3" "$4" "$5"' \
    iso-repository "$os_dir/scripts/lib/repository.sh" "$1" "$keyring_dir" "$2" "$3"
}

phase 'Stage and verify the ISO repositories'
if [[ -n "$repo_source" ]]; then
  run cp -a --reflink=auto -- "$repo_source" "$repo_dir"
  verify_repository "$repo_dir" development local-installer
else
  if (( ! dry_run )); then
    mkdir -p -- "$download_cache"
    exec {download_lock}>"$download_cache/.iso-download.lock"
    flock -n "$download_lock" || die "Another ISO download is using $download_cache."
  fi
  # Resolve ISO and local build requirements before compiling. The combined
  # local index retains individually verified, production-signed packages.
  run python3 "$os_dir/scripts/stage-iso-repositories.py" --url "$repo_url" \
    --output "$repo_dir" --cache "$download_cache" --keyring "$keyring_dir" --jobs "$jobs"
  verify_repository "$repo_dir" development local-installer
  if (( ! dry_run )); then exec {download_lock}>&-; fi
fi

phase 'Build or stage the six local installer packages'
if [[ -n "$installer_dir" ]]; then
  run env DEVARIO_CORE_REPO_DIR="$repo_dir" DEVARIO_CORE_KEYRING_DIR="$keyring_dir" \
    bash "$os_dir/scripts/stage-installer-packages.sh" "$installer_dir"
else
  run python3 "$os_dir/scripts/build-packages-core.py" --repo "$repo_dir" \
    --work "$run_dir/packages" --keyring "$keyring_dir"
  run env DEVARIO_CORE_REPO_DIR="$repo_dir" DEVARIO_CORE_KEYRING_DIR="$keyring_dir" \
    bash "$os_dir/scripts/stage-installer-packages.sh" "$run_dir/packages/artifacts"
fi

phase 'Audit the complete package closure and installed paths'
verify_repository "$repo_dir" development local-installer
run python3 "$os_dir/scripts/audit-iso-repositories.py" --database devario-core "$repo_dir/devario-core.db" \
  --packages "$os_dir/iso/packages.x86_64" --output "$run_dir/dependency-audit.json"
run python3 "$os_dir/scripts/audit-iso-package-paths.py" --files "$repo_dir/devario-core.files" \
  --dependency-audit "$run_dir/dependency-audit.json" --output "$run_dir/path-audit.json"

phase 'Assemble the Community ISO'
# sudo usually drops the caller's environment. Pass the build paths and only
# the supported validation/media options explicitly; do not depend on sudo -E.
iso_env=(DEVARIO_CORE_REPO_DIR="$repo_dir" DEVARIO_CORE_KEYRING_DIR="$keyring_dir"
  DEVARIO_CORE_REPO_URL="$repo_url" DEVARIO_WORK_DIR="$run_dir/image-work"
  DEVARIO_OUTPUT_DIR="$output_dir" DEVARIO_RELEASE_BUILD=0
  DEVARIO_VALIDATION_CACHE="$DEVARIO_VALIDATION_CACHE" XDG_CONFIG_HOME="$rlpm_config_home")
for variable in DEVARIO_VALIDATION_OFFLINE DEVARIO_VALIDATION_WHEELHOUSE \
  DEVARIO_LIVE_SIGNING_CERT DEVARIO_LIVE_SIGNING_KEY SOURCE_DATE_EPOCH; do
  if [[ -v "$variable" ]]; then iso_env+=("$variable=${!variable}"); fi
done
run sudo -n -- env "${iso_env[@]}" bash "$os_dir/scripts/build-iso.sh"

phase 'Verify the completed ISO checksum'
if (( dry_run )); then
  printf '+ verify %s/*.iso using the assembler .sha256 sidecars\n' "$output_dir"
else
  shopt -s nullglob
  images=("$output_dir"/*.iso)
  (( ${#images[@]} == 1 )) || die "Expected exactly one completed ISO in $output_dir."
  [[ -s "${images[0]}" && -s "${images[0]}.sha256" ]] || die 'The ISO or its checksum is missing/empty.'
  (cd -- "$output_dir" && sha256sum --check --strict -- "$(basename -- "${images[0]}").sha256")
  printf '\nISO ready: %s\nBuild log: %s/build.log\n' "${images[0]}" "$run_dir"
fi
