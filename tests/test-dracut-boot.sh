#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
boot_package="$project_dir/packages/devario-boot"
test_root="$(mktemp -d /tmp/devario-dracut-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT
export TEST_ROOT="$test_root"
mkdir -p "$test_root/bin" "$test_root/boot" "$test_root/modules/1.2-devario" "$test_root/helpers"
fail() { echo "Dracut test failed: $*" >&2; exit 1; }
expect_failure() { if "$@" >"$test_root/error" 2>&1; then fail "unexpected success: $*"; fi; }
source "$boot_package/kernel.sh"
printf 'version=1.2-devario\nimage=vmlinuz\nid=linux-cachyos-lts\n' > "$test_root/modules/1.2-devario/devario-kernel"
echo native-kernel > "$test_root/modules/1.2-devario/vmlinuz"
devario_kernel_select "$test_root/modules" linux-cachyos-lts
[[ "$DEVARIO_KERNEL_VERSION" == 1.2-devario ]] || fail 'native kernel selection'
[[ ! -e "$test_root/modules/1.2-devario/pkgbase" ]] || fail 'native test depends on pkgbase'
cp "$test_root/modules/1.2-devario/devario-kernel" "$test_root/metadata"
printf 'image=../../escape\n' >> "$test_root/modules/1.2-devario/devario-kernel"
expect_failure devario_kernel_select "$test_root/modules" linux-cachyos-lts
cp "$test_root/metadata" "$test_root/modules/1.2-devario/devario-kernel"
expect_failure devario_kernel_select "$test_root/modules" linux-cachyos-lts missing-version

cat > "$test_root/bin/dracut" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_ROOT/dracut.calls"
if [[ "${FAIL_DRACUT:-}" == yes || ( "${FAIL_DRACUT:-}" == fallback && "${*: -1}" == *fallback.img ) ]]; then exit 1; fi
echo generated-image > "${*: -1}"
EOF
cat > "$test_root/bin/lsinitrd" <<'EOF'
#!/bin/bash
[[ "${FAIL_INSPECTION:-}" != yes ]] || exit 1
echo usr/lib/modules/1.2-devario/kernel/driver.ko
EOF
cat > "$test_root/bin/depmod" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/depmod.calls"
EOF
cat > "$test_root/bin/mountpoint" <<'EOF'
#!/bin/bash
[[ "${BOOT_UNMOUNTED:-}" != yes ]]
EOF
cat > "$test_root/bin/install" <<'EOF'
#!/bin/bash
if [[ "${FAIL_BACKUP:-}" == yes && "${*: -1}" == */recovery/* ]]; then
  echo 'No space left on device' >&2
  exit 1
fi
exec /usr/bin/install "$@"
EOF
cat > "$test_root/bin/mv" <<'EOF'
#!/bin/bash
if [[ "${FAIL_PUBLISH:-}" == yes && "${*: -1}" == "$TEST_ROOT/boot/initramfs-linux-cachyos-lts.img" ]]; then exit 1; fi
exec /usr/bin/mv "$@"
EOF
chmod +x "$test_root/bin/"*
export PATH="$test_root/bin:$PATH"
generate() {
  "$boot_package/initramfs-update" --modules-root "$test_root/modules" \
    --boot-dir "$test_root/boot" --config-dir "$boot_package" "$@"
}
generate --mode live
[[ -s "$test_root/boot/initramfs-linux-cachyos-lts.img" ]] || fail 'live image absent'
[[ ! -e "$test_root/boot/initramfs-linux-cachyos-lts-fallback.img" ]] || fail 'live fallback leaked'
grep -q -- '--no-hostonly-cmdline' "$test_root/dracut.calls" || fail 'host command line captured'
grep -q -- '--kver 1.2-devario' "$test_root/dracut.calls" || fail 'wrong kernel version'
grep -q -- '--no-hostonly' "$test_root/dracut.calls" || fail 'live image must be generic'
echo old-kernel > "$test_root/boot/vmlinuz-linux-cachyos-lts"
echo old-image > "$test_root/boot/initramfs-linux-cachyos-lts.img"
echo old-fallback > "$test_root/boot/initramfs-linux-cachyos-lts-fallback.img"
for failure in yes fallback; do
  export FAIL_DRACUT="$failure"
  expect_failure generate --mode installed
  grep -qx old-kernel "$test_root/boot/vmlinuz-linux-cachyos-lts" || fail 'kernel changed after failed generation'
  grep -qx old-image "$test_root/boot/initramfs-linux-cachyos-lts.img" || fail 'image changed after failed generation'
  grep -qx old-fallback "$test_root/boot/initramfs-linux-cachyos-lts-fallback.img" || fail 'fallback changed after failed generation'
done
unset FAIL_DRACUT
export FAIL_INSPECTION=yes
expect_failure generate --mode installed
unset FAIL_INSPECTION
export BOOT_UNMOUNTED=yes
expect_failure generate --mode installed
unset BOOT_UNMOUNTED
export FAIL_BACKUP=yes
expect_failure generate --mode installed
unset FAIL_BACKUP
[[ ! -e "$test_root/boot/devario-recovery/linux-cachyos-lts" ]] || fail 'partial recovery pair published'
export FAIL_PUBLISH=yes
expect_failure generate --mode installed
unset FAIL_PUBLISH
grep -qx old-kernel "$test_root/boot/vmlinuz-linux-cachyos-lts" || fail 'publication failure did not restore the kernel'
grep -qx old-image "$test_root/boot/initramfs-linux-cachyos-lts.img" || fail 'publication failure did not restore the image'
generate --mode installed
grep -qx old-kernel "$test_root/boot/devario-recovery/linux-cachyos-lts/vmlinuz-linux-cachyos-lts" || fail 'previous kernel not preserved'
grep -qx old-image "$test_root/boot/devario-recovery/linux-cachyos-lts/initramfs-linux-cachyos-lts.img" || fail 'previous initramfs not preserved'
grep -qx native-kernel "$test_root/boot/vmlinuz-linux-cachyos-lts" || fail 'new kernel not deployed'
[[ -s "$test_root/boot/initramfs-linux-cachyos-lts-fallback.img" ]] || fail 'installed fallback absent'
generate --mode installed
grep -qx old-kernel "$test_root/boot/devario-recovery/linux-cachyos-lts/vmlinuz-linux-cachyos-lts" || fail 'unconfirmed update overwrote recovery kernel'

# Image signatures are required when verification is requested, including on
# transports which supply a downloaded file rather than a block device.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$test_root/key" \
  -out "$test_root/cert" -days 1 -subj /CN=devario-boot-test >/dev/null 2>&1
echo squashfs-fixture > "$test_root/image"
openssl cms -sign -binary -nocerts -noattr -in "$test_root/image" \
  -signer "$test_root/cert" -inkey "$test_root/key" -outform DER -out "$test_root/image.sig"
"$boot_package/verify-live-image" "$test_root/image" "$test_root/image.sig" "$test_root/cert" >/dev/null 2>&1
echo tampered >> "$test_root/image"
expect_failure "$boot_package/verify-live-image" "$test_root/image" "$test_root/image.sig" "$test_root/cert"
expect_failure "$boot_package/verify-live-image" "$test_root/image" "$test_root/missing.sig" "$test_root/cert"

# Exercise the real orchestration with failing/succeeding generator executables.
cp "$boot_package/boot-update" "$test_root/helpers/"
printf '#!/bin/sh\nexit 1\n' > "$test_root/helpers/initramfs-update"
printf '#!/bin/sh\necho limine >> "$TEST_ROOT/order"\n' > "$test_root/helpers/limine-update"
chmod +x "$test_root/helpers/"*
expect_failure "$test_root/helpers/boot-update" --install
[[ ! -e "$test_root/order" ]] || fail 'Limine ran after generator failure'
printf '#!/bin/sh\necho generated >> "$TEST_ROOT/order"\n' > "$test_root/helpers/initramfs-update"
"$test_root/helpers/boot-update" --install
[[ "$(cat "$test_root/order")" == $'generated\nlimine' ]] || fail 'boot update order'

# UUID-root LUKS and Btrfs subvolume must survive command-line generation.
printf 'UUID=root-filesystem / btrfs defaults,subvol=/@ 0 0\nUUID=swap-device none swap defaults 0 0\n' > "$test_root/fstab"
printf 'cryptroot UUID=1234-abcd none luks\n' > "$test_root/crypttab"
cmdline="$("$boot_package/kernel-command-line" "$test_root/fstab" "$test_root/crypttab")"
[[ "$cmdline" == *'root=UUID=root-filesystem'* && "$cmdline" == *'rd.luks.name=1234-abcd=cryptroot'* \
  && "$cmdline" == *'rootflags=subvol=/@'* && "$cmdline" == *'resume=UUID=swap-device'* ]] || fail 'encrypted root/subvolume/resume arguments'

# Package staging proves executable ownership and hook override paths.
(
  cd "$boot_package"
  source PKGBUILD
  srcdir="$boot_package" pkgdir="$test_root/package"
  package
)
[[ -x "$test_root/package/usr/lib/devario/initramfs-update" ]] || fail 'package omits generator'
for hook in 60-dracut-remove 90-dracut-install 60-mkinitcpio-remove 90-mkinitcpio-install 95-devario-limine; do
  [[ "$(readlink "$test_root/package/etc/shelly.d/hooks/$hook.hook")" == /dev/null ]] || fail "competing hook: $hook"
done

# The independent assembler has its own package, mount and template contracts.
python3 "$project_dir/scripts/run-iso-builder.py" --check
echo 'Devario dracut generation, failure recovery, package and builder tests passed.'
