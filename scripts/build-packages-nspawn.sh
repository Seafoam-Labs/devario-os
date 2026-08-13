#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"

container_root="${DEVARIO_NSPAWN_ROOT:-/var/lib/machines/devario-builder}"
bootstrap_url="${DEVARIO_BOOTSTRAP_URL:-https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst}"
bootstrap_cache="${DEVARIO_BOOTSTRAP_CACHE:-/var/cache/devario/bootstrap}"
arch_keyring="${DEVARIO_ARCH_KEYRING:-/usr/share/pacman/keyrings/archlinux.gpg}"
bootstrap_mirrorlist="$project_dir/tools/devario-nspawn/pacman.d/mirrorlist"
container_user="devario-build"
container_project_dir="/build"
marker_name=".devario-nspawn-builder"
prepare_only=0

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/build-packages-nspawn.sh [--prepare-only] [package-directory ...]

Create or reuse an official Arch systemd-nspawn package builder, bootstrap it
with the repository's Shelly package, and build baseline Devario packages into
repo/. Package transactions are performed through Shelly.

Options:
  --prepare-only  Prepare the container without building packages.
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

mapfile -t shelly_packages < <(
  find "$project_dir/repo" -maxdepth 1 -type f \
    -name 'shelly-[0-9]*.pkg.tar.zst' -print | sort -V
)
if (( ${#shelly_packages[@]} == 0 )); then
  echo "No Shelly bootstrap package exists in $project_dir/repo." >&2
  echo "Place a trusted shelly-*.pkg.tar.zst there before creating the builder." >&2
  exit 1
fi
shelly_package="${shelly_packages[-1]}"
if ! bsdtar -xOf "$shelly_package" .PKGINFO \
  | grep -Fqx 'pkgname = shelly'; then
  echo "The selected bootstrap archive is not a Shelly package: $shelly_package" >&2
  exit 1
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

# Some official bootstrap snapshots omit pacman-mirrorlist. Shelly can still
# register [core] and [extra] in that state, but those repositories have no
# download servers. Seed only a missing or empty file and preserve any mirror
# selection already configured in a reused builder.
if [[ ! -s "$container_root/etc/pacman.d/mirrorlist" ]]; then
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
run_container_root /usr/bin/shelly install standard --no-confirm \
  base-devel git sudo

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

echo "Baseline package build completed. Repository: $project_dir/repo"
echo "The container shares the host CPU; retain explicit baseline flags and"
echo "verify package ELF requirements before publishing."
