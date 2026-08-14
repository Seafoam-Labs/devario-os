#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
# shellcheck source=lib/repository.sh
source "$script_dir/lib/repository.sh"

if [[ "${1:-}" == --managed-build ]]; then
  shift
  exec "$script_dir/build-external-packages-nspawn.sh" "$@"
fi

container_root="${DEVARIO_NSPAWN_ROOT:-/var/lib/machines/devario-builder}"
bootstrap_url="${DEVARIO_BOOTSTRAP_URL:-https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst}"
bootstrap_cache="${DEVARIO_BOOTSTRAP_CACHE:-/var/cache/devario/bootstrap}"
arch_keyring="${DEVARIO_ARCH_KEYRING:-/usr/share/pacman/keyrings/archlinux.gpg}"
arch_snapshot_url="${DEVARIO_ARCH_SNAPSHOT_URL:-}"
bootstrap_mirrorlist="$project_dir/tools/devario-nspawn/pacman.d/mirrorlist"
container_user="devario-build"
container_project_dir="/build"
marker_name=".devario-nspawn-builder"
prepare_only=0
release_build="${DEVARIO_RELEASE_BUILD:-0}"
release_output=''

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/build-packages-nspawn.sh [--prepare-only] [--output DIR] [package-directory ...]

Create or reuse an official Arch systemd-nspawn package builder, bootstrap it
with the repository's Shelly package, and build baseline Devario packages into
repo/core/. Package transactions are performed through Shelly.

Options:
  --prepare-only  Prepare the container without building packages.
  --output DIR    Fresh controlled release output (required with
                  DEVARIO_RELEASE_BUILD=1)
  -h, --help      Show this help text.

Package directories:
  When supplied, build only those directories and refresh the repository with
  the existing artifacts for all other packages.

Environment:
  DEVARIO_NSPAWN_ROOT       Container root (default: /var/lib/machines/devario-builder)
  DEVARIO_BOOTSTRAP_URL     Official Arch bootstrap archive URL
  DEVARIO_BOOTSTRAP_CACHE   Download cache directory
  DEVARIO_ARCH_KEYRING      Host Arch release-key keyring
  DEVARIO_GNUPGHOME         Optional external signing-key home to bind into the container
  DEVARIO_SIGNING_KEY       Optional signing-key fingerprint passed to the package build
EOF
}

requested_packages=()
while (( $# )); do
  case "$1" in
    --prepare-only)
      prepare_only=1
      ;;
    --output)
      (( $# >= 2 )) || { echo '--output requires a directory.' >&2; exit 2; }
      release_output="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      requested_packages+=("$1")
      ;;
  esac
  shift
done

if (( prepare_only && ${#requested_packages[@]} != 0 )); then
  echo "--prepare-only cannot be combined with package directories." >&2
  exit 2
fi
if [[ "$release_build" != 0 && "$release_build" != 1 ]]; then
  echo 'DEVARIO_RELEASE_BUILD must be 0 or 1.' >&2
  exit 2
fi
if (( release_build && ! prepare_only )) && { [[ -z "$release_output" ]] || (( ${#requested_packages[@]} )); }; then
  echo 'A controlled release requires --output and the complete package set.' >&2
  exit 2
fi
if (( ! release_build )) && [[ -n "$release_output" ]]; then
  echo '--output is reserved for DEVARIO_RELEASE_BUILD=1 controlled builds.' >&2
  exit 2
fi
if (( release_build )); then
  if ! devario_validate_https_url "$bootstrap_url" \
    || [[ "$bootstrap_url" == */latest || "$bootstrap_url" == */latest/* ]]; then
    echo 'Controlled releases require an immutable HTTPS Arch bootstrap URL (not /latest/).' >&2
    exit 1
  fi
  if [[ ! "$arch_snapshot_url" =~ ^https://archive\.archlinux\.org/repos/[0-9]{4}/[0-9]{2}/[0-9]{2}/$ ]]; then
    echo 'DEVARIO_ARCH_SNAPSHOT_URL must select an exact dated Arch archive snapshot.' >&2
    exit 1
  fi
  if [[ -d "$container_root" ]] \
    && [[ -n "$(find "$container_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo 'A controlled release requires a fresh, empty DEVARIO_NSPAWN_ROOT; builder reuse is forbidden.' >&2
    exit 1
  fi
fi

if (( EUID != 0 )); then
  echo "Run this script through sudo so it can create and enter the container." >&2
  exit 1
fi
if [[ "$container_root" != /* || "$bootstrap_cache" != /* ]]; then
  echo "DEVARIO_NSPAWN_ROOT and DEVARIO_BOOTSTRAP_CACHE must be absolute paths." >&2
  exit 1
fi

if [[ ! -d "$project_dir/.git" ]]; then
  echo "Could not identify the Devario project root at $project_dir." >&2
  exit 1
fi

for command_name in awk bsdtar curl find getent gpg gpgv grep install sort stat systemd-nspawn; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required host command: $command_name" >&2
    exit 1
  fi
done
python3 -c 'import jsonschema' >/dev/null 2>&1 || {
  echo 'The host python-jsonschema module is required for controlled input/evidence validation.' >&2
  exit 1
}

if [[ ! -r "$arch_keyring" ]]; then
  echo "The Arch release-key keyring is unavailable: $arch_keyring" >&2
  exit 1
fi
if [[ ! -s "$bootstrap_mirrorlist" ]]; then
  echo "The Devario bootstrap mirrorlist is unavailable: $bootstrap_mirrorlist" >&2
  exit 1
fi

build_uid="$(stat -c '%u' "$project_dir")"
build_gid="$(stat -c '%g' "$project_dir")"
if [[ ! "$build_uid" =~ ^[0-9]+$ || ! "$build_gid" =~ ^[0-9]+$ ]]; then
  echo "Could not determine numeric ownership for $project_dir." >&2
  exit 1
fi
if (( build_uid == 0 || build_gid == 0 )); then
  echo "The project must be owned by a regular user before package building." >&2
  exit 1
fi

bootstrap_shelly_repo="${DEVARIO_SHELLY_BOOTSTRAP_REPO:-$project_dir/repo/core}"
bootstrap_keyring_dir="${DEVARIO_BOOTSTRAP_KEYRING_DIR:-$project_dir/packages/devario-keyring}"
mapfile -t shelly_packages < <(
  find "$bootstrap_shelly_repo" -maxdepth 1 -type f \
    -name 'shelly-[0-9]*.pkg.tar.zst' -print | sort -V
)
if (( ${#shelly_packages[@]} == 0 )); then
  echo "No Shelly bootstrap package exists in $bootstrap_shelly_repo." >&2
  echo "Place a trusted shelly-*.pkg.tar.zst there before creating the builder." >&2
  exit 1
fi
shelly_package="${shelly_packages[-1]}"
if ! bsdtar -xOf "$shelly_package" .PKGINFO \
  | grep -Fqx 'pkgname = shelly'; then
  echo "The selected bootstrap archive is not a Shelly package: $shelly_package" >&2
  exit 1
fi
if (( release_build )); then
  shelly_signature="$shelly_package.sig"
  [[ -f "$shelly_signature" && ! -L "$shelly_signature" ]] || {
    echo 'The controlled Shelly bootstrap package requires a detached signature.' >&2
    exit 1
  }
  devario_validate_keyring_bundle "$bootstrap_keyring_dir" devario-core production
  devario_gpgv_active_signature "$shelly_signature" "$shelly_package"
fi

run_container_root() {
  systemd-nspawn \
    --quiet \
    --register=no \
    --console=pipe \
    --resolv-conf=replace-host \
    --directory="$container_root" \
    "$@"
}

container_marker="$container_root/$marker_name"
if [[ -e "$container_root" && ! -d "$container_root" ]]; then
  echo "The requested container root is not a directory: $container_root" >&2
  exit 1
fi

if [[ ! -f "$container_marker" ]]; then
  if [[ -d "$container_root" ]] \
    && [[ -n "$(find "$container_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Refusing to overwrite an unrecognized nonempty container root:" >&2
    echo "  $container_root" >&2
    echo "Choose an empty DEVARIO_NSPAWN_ROOT or move the existing directory." >&2
    exit 1
  fi

  install -d -m 0755 "$container_root" "$bootstrap_cache"
  bootstrap_archive="$bootstrap_cache/archlinux-bootstrap-x86_64.tar.zst"
  bootstrap_signature="$bootstrap_archive.sig"
  download_archive="$bootstrap_archive.part"
  download_signature="$bootstrap_signature.part"
  verification_dir="$(mktemp -d /tmp/devario-bootstrap-gpg.XXXXXX)"
  verification_keyring="$verification_dir/archlinux.gpg"

  cleanup_downloads() {
    rm -f -- "$download_archive" "$download_signature"
    rm -rf -- "$verification_dir"
  }
  trap cleanup_downloads EXIT

  echo "Downloading the official Arch bootstrap filesystem..."
  curl --fail --location --show-error \
    --output "$download_archive" "$bootstrap_url"
  curl --fail --location --show-error \
    --output "$download_signature" "$bootstrap_url.sig"

  echo "Verifying the Arch bootstrap signature..."
  # Arch keyring packages may ship the aggregate as concatenated ASCII armor,
  # while gpgv's --keyring input must be a binary OpenPGP keyring. Normalize a
  # private temporary copy and keep gpgv as the actual verifier.
  gpg --batch --yes --dearmor \
    --output "$verification_keyring" "$arch_keyring"
  gpgv --keyring "$verification_keyring" \
    "$download_signature" "$download_archive"
  mv -f -- "$download_archive" "$bootstrap_archive"
  mv -f -- "$download_signature" "$bootstrap_signature"
  rm -rf -- "$verification_dir"
  trap - EXIT

  echo "Extracting the container filesystem at $container_root..."
  bsdtar --numeric-owner --strip-components=1 \
    -xpf "$bootstrap_archive" -C "$container_root"
  printf '%s\n' 'Devario systemd-nspawn baseline package builder' \
    > "$container_marker"
else
  echo "Reusing the Devario builder at $container_root"
fi

bootstrap_archive="$bootstrap_cache/archlinux-bootstrap-x86_64.tar.zst"
bootstrap_signature="$bootstrap_archive.sig"
if (( release_build )); then
  # Preserve and verify the exact signed repository databases used for
  # dependency resolution. Shelly's sync cache is compared byte-for-byte below.
  snapshot_id="${arch_snapshot_url#https://archive.archlinux.org/repos/}"
  snapshot_id="${snapshot_id%/}"
  snapshot_id="${snapshot_id//\//-}"
  arch_snapshot_dir="$bootstrap_cache/arch-snapshot-$snapshot_id"
  install -d -m 0755 "$arch_snapshot_dir"
  verification_dir="$(mktemp -d /tmp/devario-arch-snapshot-gpg.XXXXXX)"
  verification_keyring="$verification_dir/archlinux.gpg"
  gpg --batch --yes --dearmor --output "$verification_keyring" "$arch_keyring"
  for repository_name in core extra; do
    for suffix in db db.sig; do
      destination="$arch_snapshot_dir/$repository_name.$suffix"
      curl --fail --location --show-error \
        --output "$destination.part" \
        "$arch_snapshot_url$repository_name/os/x86_64/$repository_name.$suffix"
      mv -f -- "$destination.part" "$destination"
    done
    gpgv --keyring "$verification_keyring" \
      "$arch_snapshot_dir/$repository_name.db.sig" \
      "$arch_snapshot_dir/$repository_name.db"
  done
  rm -rf -- "$verification_dir"
  printf 'Server = %s$repo/os/$arch\n' "$arch_snapshot_url" \
    > "$container_root/etc/pacman.d/mirrorlist"
  chmod 0644 "$container_root/etc/pacman.d/mirrorlist"
fi

# Some official bootstrap snapshots omit pacman-mirrorlist. Shelly can still
# register [core] and [extra] in that state, but those repositories have no
# download servers. Seed only a missing or empty file and preserve any mirror
# selection already configured in a reused builder.
if (( ! release_build )) && [[ ! -s "$container_root/etc/pacman.d/mirrorlist" ]]; then
  echo "Installing the bootstrap Arch mirrorlist into the container..."
  install -Dm644 "$bootstrap_mirrorlist" \
    "$container_root/etc/pacman.d/mirrorlist"
fi

# The current locally trusted Shelly binary is only a bootstrap tool. It is
# replaced by the package freshly compiled against the official Arch userspace.
echo "Installing the Shelly bootstrap into the container..."
bsdtar --numeric-owner -xpf "$shelly_package" -C "$container_root"
run_container_root /usr/bin/shelly --version

echo "Initializing the Arch package trust store through Shelly..."
run_container_root /usr/bin/shelly keyring init
run_container_root /usr/bin/shelly keyring populate archlinux
run_container_root /usr/bin/shelly sync standard --no-confirm
if (( release_build )); then
  for repository_name in core extra; do
    if ! cmp -s "$arch_snapshot_dir/$repository_name.db" \
      "$container_root/var/lib/pacman/sync/$repository_name.db"; then
      echo "Shelly resolved against unexpected $repository_name database bytes." >&2
      exit 1
    fi
  done
fi
run_container_root /usr/bin/shelly upgrade standard --no-confirm
run_container_root /usr/bin/shelly install standard --no-confirm \
  base-devel git sudo python-jsonschema

# This fragment is loaded after the container's official makepkg policy by
# makepkg-shelly.conf. Explicit settings keep host or administrator fragments
# from raising the generated package ISA above original x86-64.
install -d -m 0755 "$container_root/etc/makepkg.conf.d"
cat > "$container_root/etc/makepkg.conf.d/99-devario-baseline.conf" <<'EOF'
CFLAGS="-march=x86-64 -mtune=generic -O2 -pipe -fno-plt -fexceptions -Wp,-D_FORTIFY_SOURCE=3 -Wformat -Werror=format-security -fstack-clash-protection -fcf-protection"
CXXFLAGS="$CFLAGS -Wp,-D_GLIBCXX_ASSERTIONS"
RUSTFLAGS="-C target-cpu=x86-64 -C opt-level=2"
export GOAMD64=v1
EOF

echo "Configuring container user $container_user ($build_uid:$build_gid)..."
run_container_root /usr/bin/bash -s -- \
  "$container_user" "$build_uid" "$build_gid" <<'EOF'
set -euo pipefail
requested_user="$1"
requested_uid="$2"
requested_gid="$3"

existing_user="$(getent passwd "$requested_uid" | awk -F: '{ print $1 }' || true)"
if [[ -n "$existing_user" && "$existing_user" != "$requested_user" ]]; then
  echo "Container UID $requested_uid is already owned by $existing_user." >&2
  exit 1
fi

existing_group="$(getent group "$requested_gid" | awk -F: '{ print $1 }' || true)"
if [[ -z "$existing_group" ]]; then
  groupadd --gid "$requested_gid" "$requested_user"
  existing_group="$requested_user"
fi

if [[ -z "$existing_user" ]]; then
  useradd --create-home --uid "$requested_uid" \
    --gid "$existing_group" "$requested_user"
fi

groupadd --force wheel
usermod --append --groups wheel "$requested_user"
install -d -m 0750 /etc/sudoers.d
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$requested_user" \
  > /etc/sudoers.d/devario-builder
chmod 0440 /etc/sudoers.d/devario-builder
EOF

if (( prepare_only )); then
  echo "Baseline builder is ready at $container_root"
  echo "Run this script again without --prepare-only to build packages."
  exit 0
fi

if (( release_build )); then
  # Release construction never binds the mutable checkout into the builder.
  # Export the exact committed tree, mount all inputs read-only, copy into a
  # fresh internal work directory, and bind only a fresh output directory RW.
  for release_command in python3 sha256sum; do
    command -v "$release_command" >/dev/null 2>&1 || {
      echo "Missing release command: $release_command" >&2
      exit 1
    }
  done
  release_output="$(realpath -m -- "$release_output")"
  if [[ -e "$release_output" ]] \
    && [[ -n "$(find "$release_output" -mindepth 1 -print -quit)" ]]; then
    echo "Release output must be fresh and empty: $release_output" >&2
    exit 1
  fi
  install -d -o "$build_uid" -g "$build_gid" -m 0755 "$release_output"
  release_temp="$(mktemp -d /tmp/devario-core-nspawn.XXXXXX)"
  container_release_work=''
  cleanup_release() {
    if [[ -n "$container_release_work" \
      && "$container_release_work" == /var/tmp/devario-core.* ]]; then
      run_container_root /usr/bin/rm -rf -- "$container_release_work" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$release_temp"
  }
  trap cleanup_release EXIT

  core_archive="$release_temp/devario-os.tar"
  core_report="$release_temp/devario-os.json"
  "$script_dir/verify-repository-boundary.sh" --repository "$project_dir" \
    --archive "$core_archive" --report "$core_report"
  core_snapshot="$release_temp/devario-os"
  install -d -m 0755 "$core_snapshot"
  bsdtar -xf "$core_archive" -C "$core_snapshot"
  core_commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$core_report")"
  source_date_epoch="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceDateEpoch"])' "$core_report")"
  bootstrap_archive="$bootstrap_cache/archlinux-bootstrap-x86_64.tar.zst"
  [[ -f "$bootstrap_archive" && ! -L "$bootstrap_archive" ]] || {
    echo 'Verified bootstrap archive is unavailable.' >&2
    exit 1
  }
  signing_args=()
  signing_env=()
  if [[ -z "${DEVARIO_GNUPGHOME:-}" || -z "${DEVARIO_SIGNING_KEY:-}" ]]; then
    echo 'A controlled release requires an external signing home and exact active key.' >&2
    exit 1
  fi
  signing_home="$(realpath -e -- "$DEVARIO_GNUPGHOME")"
  signing_mode="$(stat -c '%a' "$signing_home")"
  signing_owner="$(stat -c '%u' "$signing_home")"
  if [[ "$signing_mode" != 700 || "$signing_owner" != "$build_uid" ]]; then
    echo 'The external signing home must be owned by the invoking build user and mode 0700.' >&2
    exit 1
  fi
  for forbidden_root in "$project_dir" "$release_output" "$container_root" "$bootstrap_cache"; do
    forbidden_root="$(realpath -m -- "$forbidden_root")"
    if [[ "$signing_home" == "$forbidden_root" || "$signing_home" == "$forbidden_root/"* ]]; then
      echo 'The signing home must be physically outside source, output, builder, and input roots.' >&2
      exit 1
    fi
  done
  source "$script_dir/lib/repository.sh"
  devario_validate_keyring_bundle "$project_dir/packages/devario-keyring" devario-core production
  devario_require_active_secret_signer "$signing_home" "$DEVARIO_SIGNING_KEY"
  signing_key="$DEVARIO_SIGNING_FINGERPRINT"
  signing_args+=(--bind="$signing_home:/signing")
  signing_env+=(
    --setenv=DEVARIO_GNUPGHOME=/signing
    --setenv="DEVARIO_SIGNING_KEY=$signing_key"
  )

  # Resolve and install the complete package build dependency closure before
  # freezing the one-shot builder identity. This mode cannot emit artifacts.
  prepare_nspawn=(
    --quiet --register=no --console=pipe --resolv-conf=replace-host
    --directory="$container_root"
    --bind-ro="$core_snapshot:/input/devario-os"
  )
  run_prepare_root() { systemd-nspawn "${prepare_nspawn[@]}" "$@"; }
  container_release_work="$(run_prepare_root /usr/bin/mktemp -d /var/tmp/devario-core.XXXXXX)"
  [[ "$container_release_work" == /var/tmp/devario-core.* ]] || {
    echo 'The container returned an unsafe release-work path.' >&2
    exit 1
  }
  run_prepare_root /usr/bin/install -d -m 0755 \
    "$container_release_work/source" "$container_release_work/package-work" \
    "$container_release_work/repo" "$container_release_work/sources"
  run_prepare_root /usr/bin/cp -a /input/devario-os/. "$container_release_work/source/"
  run_prepare_root /usr/bin/chown -R "$build_uid:$build_gid" "$container_release_work"
  systemd-nspawn "${prepare_nspawn[@]}" \
    --user="$container_user" \
    --chdir="$container_release_work/source" \
    --setenv="DEVARIO_PACKAGE_OUTPUT_DIR=$container_release_work/repo" \
    --setenv="DEVARIO_SOURCE_OUTPUT_DIR=$container_release_work/sources" \
    --setenv="DEVARIO_PACKAGE_WORK_DIR=$container_release_work/package-work" \
    --setenv=DEVARIO_RELEASE_BUILD=1 \
    --setenv=DEVARIO_BUILDER_PREPARE=1 \
    --setenv=DEVARIO_VERIFIED_SOURCE=1 \
    --setenv=DEVARIO_KEY_POLICY=production \
    --setenv="DEVARIO_CORE_COMMIT=$core_commit" \
    --setenv="DEVARIO_CORE_SOURCE_DATE_EPOCH=$source_date_epoch" \
    --setenv="SOURCE_DATE_EPOCH=$source_date_epoch" \
    /usr/bin/env -u LD_PRELOAD ./scripts/build-packages.sh

  run_prepare_root /usr/bin/rm -rf -- "$container_release_work"
  container_release_work=''
  for repository_name in core extra; do
    cmp -s "$arch_snapshot_dir/$repository_name.db" \
      "$container_root/var/lib/pacman/sync/$repository_name.db" || {
      echo "Prepared builder drifted from locked $repository_name database." >&2
      exit 1
    }
  done

  dependency_closure="$release_temp/dependency-closure.json"
  CONTAINER_ROOT="$container_root" python3 - > "$dependency_closure" <<'PY'
import json, os, pathlib
root=pathlib.Path(os.environ["CONTAINER_ROOT"])/"var/lib/pacman/local"
records=[]
for desc in sorted(root.glob("*/desc")):
 lines=desc.read_text(encoding="utf-8").splitlines(); fields={}; i=0
 while i < len(lines):
  if lines[i].startswith("%") and lines[i].endswith("%") and i+1 < len(lines): fields[lines[i][1:-1]]=lines[i+1]; i+=2
  else: i+=1
 if not all(fields.get(key) for key in ("NAME","VERSION","ARCH")): raise SystemExit(f"incomplete local package record: {desc}")
 records.append({"name":fields["NAME"],"version":fields["VERSION"],"architecture":fields["ARCH"]})
records.sort(key=lambda item:item["name"])
if not records or len({item["name"] for item in records}) != len(records): raise SystemExit("invalid builder dependency closure")
print(json.dumps(records,sort_keys=True,separators=(",",":")))
PY
  container_manifest="$container_root/etc/devario/controlled-builder.json"
  install -d -m 0755 "$(dirname -- "$container_manifest")"
  builder_root_digest="$($script_dir/tree-closure-digest.py --root "$container_root" \
    --exclude dev --exclude proc --exclude sys --exclude run --exclude tmp \
    --exclude var/tmp --exclude input --exclude output --exclude signing \
    --exclude etc/resolv.conf --exclude etc/devario/controlled-builder.json \
    --exclude etc/devario/controlled-builder.json.sig)"
  "$script_dir/write-controlled-builder-manifest.py" \
    --root-tree-sha256 "$builder_root_digest" \
    --arch-snapshot-url "$arch_snapshot_url" \
    --arch-snapshot-dir "$arch_snapshot_dir" \
    --bootstrap-archive "$bootstrap_archive" \
    --bootstrap-signature "$bootstrap_signature" \
    --bootstrap-url "$bootstrap_url" \
    --shelly-bootstrap "$shelly_package" \
    --shelly-bootstrap-signature "$shelly_signature" \
    --dependency-closure "$dependency_closure" \
    --output "$container_manifest"
  GNUPGHOME="$signing_home" gpg --batch --yes --detach-sign \
    --local-user "$signing_key" --output "$container_manifest.sig" "$container_manifest"
  chmod 0444 "$container_manifest" "$container_manifest.sig"
  devario_gpgv_active_signature "$container_manifest.sig" "$container_manifest"

  normalized_arch_keyring="$release_temp/archlinux.gpg"
  gpg --batch --yes --dearmor --output "$normalized_arch_keyring" "$arch_keyring"
  input_lock="$release_temp/CORE-INPUT-LOCK.json"
  lock_args=(
    --operation packages --core "$project_dir"
    --edition "$project_dir/editions/community"
    --bootstrap-archive "$bootstrap_archive" --bootstrap-signature "$bootstrap_signature"
    --bootstrap-url "$bootstrap_url" --arch-snapshot-dir "$arch_snapshot_dir"
    --arch-snapshot-url "$arch_snapshot_url" --arch-keyring "$normalized_arch_keyring"
    --shelly-bootstrap "$shelly_package" --shelly-bootstrap-signature "$shelly_signature"
    --builder-manifest "$container_manifest" --builder-manifest-signature "$container_manifest.sig"
    --builder-keyring "$project_dir/packages/devario-keyring" --builder-repository devario-core
    --dependency-closure "$dependency_closure" --source-date-epoch "$source_date_epoch"
    --core-keyring "$project_dir/packages/devario-keyring"
  )
  lock_args+=(--core-repo "$bootstrap_shelly_repo")
  "$script_dir/create-core-input-lock.sh" "${lock_args[@]}" --output "$input_lock"
  install -m 0444 "$input_lock" "$release_output/CORE-INPUT-LOCK.json"

  observed_root_digest="$($script_dir/tree-closure-digest.py --root "$container_root" \
    --exclude dev --exclude proc --exclude sys --exclude run --exclude tmp \
    --exclude var/tmp --exclude input --exclude output --exclude signing \
    --exclude etc/resolv.conf --exclude etc/devario/controlled-builder.json \
    --exclude etc/devario/controlled-builder.json.sig)"
  [[ "$observed_root_digest" == "$builder_root_digest" ]] || {
    echo 'Controlled builder root changed before construction.' >&2; exit 1;
  }
  release_nspawn=(
    --quiet --register=no --console=pipe --resolv-conf=replace-host
    --directory="$container_root"
    --bind-ro="$core_snapshot:/input/devario-os"
    --bind-ro="$input_lock:/input/CORE-INPUT-LOCK.json"
    --bind-ro="$container_manifest:/run/devario-controlled-builder/manifest.json"
    --bind-ro="$container_manifest.sig:/run/devario-controlled-builder/manifest.json.sig"
    --bind="$release_output:/output" "${signing_args[@]}"
  )
  run_release_root() { systemd-nspawn "${release_nspawn[@]}" "$@"; }
  container_release_work="$(run_release_root /usr/bin/mktemp -d /var/tmp/devario-core.XXXXXX)"
  [[ "$container_release_work" == /var/tmp/devario-core.* ]] || { echo 'Unsafe container work path.' >&2; exit 1; }
  run_release_root /usr/bin/install -d -m 0755 "$container_release_work/source" "$container_release_work/package-work"
  run_release_root /usr/bin/cp -a /input/devario-os/. "$container_release_work/source/"
  run_release_root /usr/bin/chown -R "$build_uid:$build_gid" "$container_release_work"
  systemd-nspawn "${release_nspawn[@]}" --user="$container_user" \
    --chdir="$container_release_work/source" \
    --setenv=DEVARIO_CONTROLLED_NSPAWN=1 --setenv=DEVARIO_EXPECTED_OPERATION=packages \
    --setenv=DEVARIO_INPUT_LOCK=/input/CORE-INPUT-LOCK.json \
    --setenv=DEVARIO_PACKAGE_OUTPUT_DIR=/output/devario-core \
    --setenv=DEVARIO_SOURCE_OUTPUT_DIR=/output/sources \
    --setenv="DEVARIO_PACKAGE_WORK_DIR=$container_release_work/package-work" \
    --setenv=DEVARIO_RELEASE_BUILD=1 --setenv=DEVARIO_VERIFIED_SOURCE=1 \
    --setenv=DEVARIO_KEY_POLICY=production --setenv=DEVARIO_REPOSITORY_NAME=devario-core \
    --setenv="DEVARIO_CORE_COMMIT=$core_commit" \
    --setenv="DEVARIO_CORE_SOURCE_DATE_EPOCH=$source_date_epoch" \
    --setenv="SOURCE_DATE_EPOCH=$source_date_epoch" "${signing_env[@]}" \
    /usr/bin/env -u LD_PRELOAD ./scripts/build-packages.sh

  install -m 0444 "$container_manifest" "$release_output/CONTROLLED-BUILDER.json"
  install -m 0444 "$container_manifest.sig" "$release_output/CONTROLLED-BUILDER.json.sig"
  "$script_dir/write-builder-attestation.sh" \
    --input-lock "$input_lock" \
    --output-tree "$release_output" \
    --builder-marker "$container_manifest" \
    --builder-packages "$dependency_closure" \
    --operation packages \
    --keyring-dir "$project_dir/packages/devario-keyring" \
    --repository-name devario-core \
    --signing-home "$signing_home" --signing-key "$signing_key" \
    --output "$release_output/BUILDER-ATTESTATION.json"
  printf '%s\n' "consumed core build $core_commit" > "$container_root/.devario-controlled-builder-consumed"
  chmod 0444 "$container_root/.devario-controlled-builder-consumed"
  echo "Controlled core package output: $release_output"
  exit 0
fi

build_container_args=(
  --quiet
  --register=no
  --console=pipe
  --resolv-conf=replace-host
  --directory="$container_root"
  --bind="$project_dir:$container_project_dir"
  --chdir="$container_project_dir"
  --user="$container_user"
)

if [[ -n "${DEVARIO_SIGNING_KEY:-}" ]]; then
  build_container_args+=(--setenv="DEVARIO_SIGNING_KEY=$DEVARIO_SIGNING_KEY")
fi
if [[ -n "${DEVARIO_GNUPGHOME:-}" ]]; then
  if [[ ! -d "$DEVARIO_GNUPGHOME" ]]; then
    echo "DEVARIO_GNUPGHOME is not a directory: $DEVARIO_GNUPGHOME" >&2
    exit 1
  fi
  build_container_args+=(
    --bind="$DEVARIO_GNUPGHOME:/devario-signing"
    --setenv=DEVARIO_GNUPGHOME=/devario-signing
  )
fi

echo "Building Devario packages in the baseline container..."
systemd-nspawn "${build_container_args[@]}" \
  /usr/bin/env -u LD_PRELOAD \
  ./scripts/build-packages.sh "${requested_packages[@]}"

echo "Baseline package build completed. Repository: $project_dir/repo/core"
echo "The container shares the host CPU; retain explicit baseline flags and"
echo "verify package ELF requirements before publishing."
