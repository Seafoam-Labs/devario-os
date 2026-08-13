#!/usr/bin/env bash

set -euo pipefail
unset LD_PRELOAD

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
gpu_setup="$project_dir/packages/devario-aqueous-desktop/gpu-driver-setup"
mock_modprobe="$script_dir/fixtures/gpu-driver-setup/mock-modprobe"
test_root="$(mktemp -d /tmp/devario-gpu-driver-test.XXXXXX)"

cleanup() {
    case "$test_root" in
        /tmp/devario-gpu-driver-test.*)
            rm -rf -- "$test_root"
            ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'GPU driver test failed: %s\n' "$*" >&2
    exit 1
}

create_pci_device() {
    local address="$1" vendor="$2" class="$3"
    local device="$test_root/pci/$address"

    mkdir -p "$device"
    printf '%s\n' "$vendor" > "$device/vendor"
    printf '%s\n' "$class" > "$device/class"
}

run_setup() {
    local mode="$1" device="$2"

    : > "$test_root/modprobe.log"
    env \
        DEVARIO_PCI_DEVICES_ROOT="$test_root/pci" \
        DEVARIO_GPU_STATE_FILE="$test_root/state/gpu-driver" \
        DEVARIO_MODPROBE="$mock_modprobe" \
        DEVARIO_UDEVADM=/usr/bin/true \
        DEVARIO_TEST_MODPROBE_LOG="$test_root/modprobe.log" \
        DEVARIO_TEST_DRIVER_MODE="$mode" \
        DEVARIO_TEST_DRIVER_ROOT="$test_root/drivers" \
        DEVARIO_TEST_NVIDIA_DEVICE="$device" \
        bash "$gpu_setup" --setup
}

mkdir -p "$test_root/pci" "$test_root/drivers/nvidia"
create_pci_device 0000:00:02.0 0x8086 0x030000

if env DEVARIO_PCI_DEVICES_ROOT="$test_root/pci" \
    bash "$gpu_setup" --detect >/dev/null; then
    fail "an Intel display controller was detected as NVIDIA"
fi

run_setup unavailable "$test_root/pci/0000:01:00.0"
[[ "$(<"$test_root/state/gpu-driver")" == none ]] \
    || fail "a non-NVIDIA system did not record the none state"
[[ ! -s "$test_root/modprobe.log" ]] \
    || fail "the NVIDIA module was loaded without NVIDIA hardware"

create_pci_device 0000:01:00.0 0x10DE 0x030000
create_pci_device 0000:01:00.1 0x10de 0x040300

detected="$(env DEVARIO_PCI_DEVICES_ROOT="$test_root/pci" \
    bash "$gpu_setup" --detect)"
[[ "$detected" == 0000:01:00.0 ]] \
    || fail "detection did not isolate the NVIDIA display function"

run_setup nvidia "$test_root/pci/0000:01:00.0"
[[ "$(<"$test_root/state/gpu-driver")" == nvidia ]] \
    || fail "a bound NVIDIA device did not record the nvidia state"
grep -Fqx 'nvidia_drm modeset=1' "$test_root/modprobe.log" \
    || fail "the NVIDIA DRM module was not loaded with modesetting"

rm -f -- "$test_root/pci/0000:01:00.0/driver"
run_setup unavailable "$test_root/pci/0000:01:00.0"
[[ "$(<"$test_root/state/gpu-driver")" == unavailable ]] \
    || fail "a module-load failure did not record the unavailable state"

printf 'GPU driver setup tests passed.\n'
