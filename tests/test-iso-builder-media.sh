#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Uses real bootloaders/kernel/dracut with a tiny static root, not the desktop ISO.
set -euo pipefail
(( $# == 3 )) || { echo "Usage: $0 KERNEL LIVE_INITRAMFS VERIFIED_SYSLINUX_PACKAGE" >&2; exit 64; }
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/devario-media-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root"/{root,work,out,profile,builder}
cp -a "$project_dir/iso/." "$test_root/profile/"
bsdtar -xf "$project_dir/tools/devario-iso-builder/devario-iso-builder.tar.gz" -C "$test_root/builder"
bsdtar -xf "$3" -C "$test_root/root" usr/lib/syslinux
mkdir -p "$test_root/root/"{boot,sbin,etc,dev,proc,sys,run,tmp,usr/lib/systemd/boot/efi}
cp "$1" "$test_root/root/boot/vmlinuz-linux-cachyos-lts"
cp "$2" "$test_root/root/boot/initramfs-linux-cachyos-lts.img"
cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi "$test_root/root/usr/lib/systemd/boot/efi/"
printf 'ID=devario\nNAME=Devario\n' > "$test_root/root/etc/os-release"
touch "$test_root/root/etc/devario-smoke"
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=Devario-Media-Test \
  -keyout "$test_root/test.key" -out "$test_root/test.pem" -days 1 >/dev/null 2>&1
cat > "$test_root/init.c" <<'C'
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/reboot.h>
int main(void) {
    int fd = open("/dev/console", O_RDWR); dup2(fd,1); dup2(fd,2);
    int ok = access("/run/devario/live",F_OK)==0 && access("/run/devario/install-root/etc/devario-smoke",F_OK)==0;
    printf("\nDEVARIO_ISO_MEDIA:%s\n",ok?"PASS":"FAIL"); fflush(stdout);
    sync(); reboot(RB_POWER_OFF); for (;;) pause();
}
C
cc -static -Os -o "$test_root/root/sbin/init" "$test_root/init.c"
SOURCE_DATE_EPOCH=1789488000 TEST_ROOT="$test_root" python3 - <<'PY'
import importlib.util,os,pathlib
r=pathlib.Path(os.environ['TEST_ROOT'])
spec=importlib.util.spec_from_file_location('builder',r/'builder/devario-iso-builder/builder.py');b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
for p in list((r/'profile/syslinux').glob('*.cfg'))+list((r/'profile/efiboot/loader/entries').glob('*.conf')):
 s=p.read_text().replace('rd.overlay=1','rd.overlay=1 console=ttyS0 rd.shell=0 panic=1');p.write_text(s)
(r/'profile/efiboot/loader/loader.conf').write_text('timeout 1\ndefault 01-devario-linux.conf\n')
m=dict(name='devario-media-test',version='1',label='DEVARIO_TEST',publisher='Devario Project',application='Devario media integration test',epoch=1789488000,kernelId='linux-cachyos-lts',signing={'certificate':str(r/'test.pem'),'key':str(r/'test.key')})
(r/'media').mkdir()
temporary,target=b.assemble(r/'root',r/'profile',r/'media',r/'work',r/'out',m)
temporary.rename(target)
print('BIOS/UEFI media assembly passed:',target)
PY
openssl cms -verify -binary -inform DER -in "$test_root/media/devario/x86_64/airootfs.sfs.cms.sig" \
  -content "$test_root/media/devario/x86_64/airootfs.sfs" -CAfile "$test_root/test.pem" -out /dev/null
iso="$test_root/out/devario-media-test-1-x86_64.iso"
cpu=max
[[ "${DEVARIO_TEST_ACCELERATOR:-tcg}" != kvm ]] || cpu=host
for firmware in bios uefi; do
  args=()
  if [[ "$firmware" == uefi ]]; then
    cp /usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd "$test_root/vars.fd"
    args=(-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd
          -drive "if=pflash,format=raw,file=$test_root/vars.fd")
  fi
  status=0
  timeout 180 qemu-system-x86_64 -accel "${DEVARIO_TEST_ACCELERATOR:-tcg}" -cpu "$cpu" -m 2048 -smp 2 \
    -display none -serial stdio -monitor none -no-reboot "${args[@]}" -cdrom "$iso" \
    > "$test_root/$firmware.log" 2>&1 || status=$?
  if (( status != 0 )) || ! grep -q 'DEVARIO_ISO_MEDIA:PASS' "$test_root/$firmware.log"; then
    cat "$test_root/$firmware.log" >&2
    exit 1
  fi
  echo "Devario assembled ISO firmware boot passed: $firmware"
done
