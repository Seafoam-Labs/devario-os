#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Integration probe for an already generated live initramfs. Uses a tiny root,
# direct kernel boot; this does not replace the full ISO acceptance matrix.
set -euo pipefail
if (( $# != 2 )); then
  echo "Usage: $0 KERNEL LIVE-INITRAMFS" >&2
  exit 64
fi
kernel="$(realpath -e "$1")"
initramfs="$(realpath -e "$2")"
test_root="$(mktemp -d /tmp/devario-live-qemu.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/root/"{sbin,etc,usr,dev,proc,sys,run,tmp} "$test_root/iso/devario/x86_64"
cat > "$test_root/init.c" <<'EOF'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <unistd.h>
int main(void) {
    int console = open("/dev/console", O_RDWR);
    dup2(console, 1); dup2(console, 2);
    int ok = access("/run/devario/live", F_OK) == 0 &&
             access("/run/devario/install-root/etc/devario-smoke", F_OK) == 0;
    int fd = open("/live-only", O_CREAT | O_WRONLY, 0600);
    ok &= fd >= 0;
    if (fd >= 0) close(fd);
    ok &= access("/run/devario/install-root/live-only", F_OK) != 0;
    errno = 0;
    fd = open("/run/devario/install-root/forbidden", O_CREAT | O_WRONLY, 0600);
    ok &= fd < 0 && errno == EROFS;
    if (fd >= 0) close(fd);
    FILE *cmd = fopen("/proc/cmdline", "r");
    char line[4096] = {0};
    if (cmd) { fgets(line, sizeof(line), cmd); fclose(cmd); }
    if (strstr(line, "rd.live.ram=1")) {
        FILE *mounts = fopen("/proc/self/mountinfo", "r");
        if (!mounts) ok = 0;
        else {
            while (fgets(line, sizeof(line), mounts))
                if (strstr(line, " /run/initramfs/live ")) ok = 0;
            fclose(mounts);
        }
    }
    printf("\nDEVARIO_DRACUT_SMOKE:%s\n", ok ? "PASS" : "FAIL");
    fflush(stdout);
    sync(); reboot(RB_POWER_OFF);
    for (;;) pause();
}
EOF
cc -static -Os -o "$test_root/root/sbin/init" "$test_root/init.c"
printf 'ID=devario\nNAME=Devario\n' > "$test_root/root/etc/os-release"
touch "$test_root/root/etc/devario-smoke"
mksquashfs "$test_root/root" "$test_root/iso/devario/x86_64/airootfs.sfs" -noappend -all-root -quiet
xorriso -as mkisofs -quiet -V DEVARIO_SMOKE -o "$test_root/live.iso" "$test_root/iso"
accelerator="${DEVARIO_TEST_ACCELERATOR:-tcg}"
cpu=max
[[ "$accelerator" != kvm ]] || cpu=host
for copy_to_ram in 0 1; do
  log="$test_root/qemu-$copy_to_ram.log"
  status=0
  timeout 180 qemu-system-x86_64 -accel "$accelerator" -cpu "$cpu" -m 2048 -smp 2 -display none \
    -serial stdio -monitor none -no-reboot -kernel "$kernel" -initrd "$initramfs" \
    -cdrom "$test_root/live.iso" \
    -append "root=live:LABEL=DEVARIO_SMOKE rd.live.dir=devario/x86_64 rd.live.squashimg=airootfs.sfs rd.overlay=1 rd.live.ram=$copy_to_ram console=ttyS0 rd.shell=0 panic=1 ${DEVARIO_TEST_CMDLINE:-}" \
    > "$log" 2>&1 || status=$?
  if (( status != 0 )) || ! grep -qx 'DEVARIO_DRACUT_SMOKE:PASS' <(tr -d '\r' < "$log"); then
    cat "$log" >&2
    exit 1
  fi
  echo "Dracut live-root probe passed (copy-to-RAM=$copy_to_ram)."
done
