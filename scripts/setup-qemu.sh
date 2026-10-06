#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"

firmware_mode=uefi
install_only=0
disk_only=0
force_software=0
enable_gl=1
dry_run=0
iso_path=""

usage() {
  cat <<'EOF'
Usage: ./scripts/setup-qemu.sh [options]

Install QEMU and OVMF through Shelly when necessary, prepare a persistent
Devario test VM, and boot the newest ISO in out/.

Options:
  --install-only  Install and configure QEMU without starting the VM
  --iso PATH      Boot a specific ISO instead of the newest out/devario-*.iso
  --disk-only     Boot the installed VM disk without attaching an ISO
  --uefi          Boot with OVMF UEFI firmware (default)
  --bios          Boot live media with legacy BIOS firmware (installation requires UEFI)
  --software      Disable KVM and use software CPU emulation
  --no-gl         Console boot testing only; disables the Vulkan desktop GPU
  --dry-run       Prepare state and print the QEMU command without running it
  -h, --help      Show this help

Environment:
  DEVARIO_QEMU_MEMORY     Guest memory (default: 6G)
  DEVARIO_QEMU_CPUS       Guest CPU count (default: 4)
  DEVARIO_QEMU_DISK_SIZE  Sparse test-disk size (default: 64G)
  DEVARIO_QEMU_STATE_DIR  VM state directory (default: out/qemu)
  DEVARIO_QEMU_HOSTMEM    Venus GPU host-visible memory aperture (default: 4G)
  DEVARIO_QEMU_FIRMWARE_DIR  Optional directory to search first for OVMF
EOF
}

die() {
  echo "QEMU setup error: $*" >&2
  exit 1
}

warn() {
  echo "QEMU setup warning: $*" >&2
}

while (( $# )); do
  case "$1" in
    --install-only)
      install_only=1
      ;;
    --iso)
      shift
      (( $# )) || die "--iso requires a path"
      iso_path="$1"
      ;;
    --disk-only)
      disk_only=1
      ;;
    --uefi)
      firmware_mode=uefi
      ;;
    --bios)
      firmware_mode=bios
      ;;
    --software)
      force_software=1
      ;;
    --no-gl)
      enable_gl=0
      ;;
    --dry-run)
      dry_run=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

if (( disk_only )) && [[ "$firmware_mode" == bios ]]; then
  die "installed Devario uses systemd-boot and requires --uefi"
fi

if (( EUID == 0 )); then
  die "run this helper as your desktop user, without sudo; it elevates individual setup steps when needed"
fi
if (( disk_only )) && [[ -n "$iso_path" ]]; then
  die "--disk-only and --iso cannot be used together"
fi

memory="${DEVARIO_QEMU_MEMORY:-6G}"
hostmem="${DEVARIO_QEMU_HOSTMEM:-4G}"
cpus="${DEVARIO_QEMU_CPUS:-4}"
disk_size="${DEVARIO_QEMU_DISK_SIZE:-64G}"
state_dir="${DEVARIO_QEMU_STATE_DIR:-$project_dir/out/qemu}"
if [[ "$state_dir" != /* ]]; then
  state_dir="$project_dir/$state_dir"
fi

[[ "$memory" =~ ^[1-9][0-9]*([MGT])?$ ]] \
  || die "DEVARIO_QEMU_MEMORY must be a positive size such as 6G"
[[ "$hostmem" =~ ^[1-9][0-9]*[MGT]$ ]] \
  || die "DEVARIO_QEMU_HOSTMEM must be a positive size with a unit, such as 4G"
[[ "$cpus" =~ ^[1-9][0-9]*$ ]] \
  || die "DEVARIO_QEMU_CPUS must be a positive integer"
[[ "$disk_size" =~ ^[1-9][0-9]*([MGT])?$ ]] \
  || die "DEVARIO_QEMU_DISK_SIZE must be a positive size such as 64G"

firmware_code=""
firmware_vars_template=""

find_ovmf() {
  local firmware_dir
  local firmware_pair
  local code_name
  local vars_name
  local -a firmware_dirs=()
  if [[ -n "${DEVARIO_QEMU_FIRMWARE_DIR:-}" ]]; then
    firmware_dirs+=("$DEVARIO_QEMU_FIRMWARE_DIR")
  fi
  firmware_dirs+=(
    /usr/share/edk2/x64
    /usr/share/edk2/ovmf
    /usr/share/OVMF
  )
  local -a firmware_names=(
    'OVMF_CODE.4m.fd|OVMF_VARS.4m.fd'
    'OVMF_CODE_4M.fd|OVMF_VARS_4M.fd'
    'OVMF_CODE.fd|OVMF_VARS.fd'
  )

  firmware_code=""
  firmware_vars_template=""
  for firmware_dir in "${firmware_dirs[@]}"; do
    for firmware_pair in "${firmware_names[@]}"; do
      code_name="${firmware_pair%%|*}"
      vars_name="${firmware_pair#*|}"
      if [[ -r "$firmware_dir/$code_name" \
        && -r "$firmware_dir/$vars_name" ]]; then
        firmware_code="$firmware_dir/$code_name"
        firmware_vars_template="$firmware_dir/$vars_name"
        return 0
      fi
    done
  done
  return 1
}

dependencies_ready() {
  command -v qemu-system-x86_64 >/dev/null 2>&1 \
    && command -v qemu-img >/dev/null 2>&1 \
    && find_ovmf \
    && { (( ! enable_gl )) || command -v vulkaninfo >/dev/null 2>&1; }
}

if ! dependencies_ready; then
  command -v shelly >/dev/null 2>&1 \
    || die "Shelly is required to install qemu-desktop, edk2-ovmf, and vulkan-tools"
  echo "Installing QEMU and OVMF through Shelly..."
  shelly install standard --upgrade qemu-desktop edk2-ovmf vulkan-tools
  hash -r
fi

command -v qemu-system-x86_64 >/dev/null 2>&1 \
  || die "qemu-system-x86_64 is unavailable after package setup"
command -v qemu-img >/dev/null 2>&1 \
  || die "qemu-img is unavailable after package setup"
find_ovmf || die "OVMF firmware was not found after installing edk2-ovmf"

acceleration=tcg
cpu_model=max
if (( ! force_software )); then
  if [[ ! -e /dev/kvm ]] \
    && grep -Eqm1 '(^|[[:space:]])(vmx|svm)([[:space:]]|$)' /proc/cpuinfo \
    && command -v modprobe >/dev/null 2>&1 \
    && command -v sudo >/dev/null 2>&1; then
    echo "Loading the host KVM modules..."
    sudo modprobe kvm || true
    if grep -Fqm1 'GenuineIntel' /proc/cpuinfo; then
      sudo modprobe kvm_intel || true
    elif grep -Fqm1 'AuthenticAMD' /proc/cpuinfo; then
      sudo modprobe kvm_amd || true
    fi
  fi

  if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    acceleration=kvm
    cpu_model=host
  elif [[ -c /dev/kvm ]] \
    && command -v getent >/dev/null 2>&1 \
    && getent group kvm >/dev/null 2>&1 \
    && ! id -nG | tr ' ' '\n' | grep -Fxq kvm \
    && command -v sudo >/dev/null 2>&1; then
    echo "Adding $(id -un) to the kvm group for future accelerated VM runs..."
    if sudo usermod -aG kvm "$(id -un)"; then
      warn "KVM access will take effect after you sign out and back in; using software emulation now"
    else
      warn "could not add $(id -un) to the kvm group; using software emulation"
    fi
  else
    warn "KVM is unavailable to this session; using slower software emulation"
  fi
fi

if (( install_only )); then
  echo "QEMU and OVMF are ready. Run ./scripts/setup-qemu.sh to boot the newest ISO."
  exit 0
fi

if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
  die "no graphical session was detected; run this helper from the desktop"
fi

if (( enable_gl )); then
  # shellcheck source=lib/qemu-graphics.sh
  source "$script_dir/lib/qemu-graphics.sh"
  devario_qemu_check_venus || die 'Venus desktop prerequisites are unavailable'
else
  warn '--no-gl boots the console only; Aqueous and Pearl Greeter require Vulkan'
fi

if (( ! disk_only )); then
  if [[ -n "$iso_path" ]]; then
    [[ -f "$iso_path" ]] || die "ISO does not exist: $iso_path"
  else
    shopt -s nullglob
    iso_candidates=("$project_dir"/out/devario-*.iso)
    shopt -u nullglob
    (( ${#iso_candidates[@]} )) \
      || die "no ISO was found in out/; build one or pass --iso PATH"
    iso_path="${iso_candidates[0]}"
    for candidate in "${iso_candidates[@]:1}"; do
      if [[ "$candidate" -nt "$iso_path" ]]; then
        iso_path="$candidate"
      fi
    done
  fi
fi

mkdir -p -- "$state_dir"
disk_path="$state_dir/devario-$firmware_mode.qcow2"
if [[ ! -f "$disk_path" ]]; then
  if (( disk_only )); then
    die "the $firmware_mode VM disk does not exist yet; boot the ISO and install it first"
  fi
  echo "Creating sparse $disk_size $firmware_mode test disk at $disk_path"
  qemu-img create -f qcow2 "$disk_path" "$disk_size"
fi

accelerator_options="$acceleration"
if (( enable_gl )) && [[ "$acceleration" == kvm ]] \
  && grep -Fqm1 'GenuineIntel' /proc/cpuinfo; then
  # Venus host-visible mappings on Intel require QEMU 11+ honoring guest PAT.
  accelerator_options+=',honor-guest-pat=on'
fi

qemu_args=(
  -name 'Devario ISO Test'
  -machine q35
  -accel "$accelerator_options"
  -cpu "$cpu_model"
  -smp "$cpus"
  -m "$memory"
  -device qemu-xhci
  -device usb-tablet
  -nic user,model=virtio-net-pci
  -drive "file=$disk_path,if=virtio,format=qcow2,discard=unmap"
)

if (( enable_gl )); then
  # -m interprets a bare number as MiB; memory-backend-memfd interprets it as
  # bytes. Normalize the latter so both describe the same guest RAM.
  ram_size="$memory"
  [[ "$ram_size" =~ [MGT]$ ]] || ram_size="${ram_size}M"
  qemu_args+=(
    -object "memory-backend-memfd,id=devario-ram,size=$ram_size,share=on"
    -machine memory-backend=devario-ram
    -device "virtio-vga-gl,hostmem=$hostmem,blob=true,venus=true"
    -display gtk,gl=on
  )
else
  qemu_args+=(
    -device virtio-vga
    -display gtk,gl=off
  )
fi

if [[ "$firmware_mode" == uefi ]]; then
  vars_size="$(stat -c '%s' "$firmware_vars_template")"
  firmware_vars="$state_dir/OVMF_VARS-$vars_size.fd"
  if [[ ! -f "$firmware_vars" ]]; then
    install -m 0644 "$firmware_vars_template" "$firmware_vars"
  fi
  qemu_args+=(
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$firmware_code"
    -drive "if=pflash,format=raw,unit=1,file=$firmware_vars"
  )
fi

if (( disk_only )); then
  qemu_args+=( -boot menu=on,order=c )
  echo "Starting the installed $firmware_mode VM from $disk_path"
else
  qemu_args+=(
    -drive "file=$iso_path,media=cdrom,readonly=on"
    -boot menu=on,order=d
  )
  echo "Starting $iso_path with $firmware_mode firmware ($acceleration acceleration)"
fi

if (( dry_run )); then
  printf 'QEMU command:'
  printf ' %q' qemu-system-x86_64 "${qemu_args[@]}"
  printf '\n'
  exit 0
fi

exec qemu-system-x86_64 "${qemu_args[@]}"
