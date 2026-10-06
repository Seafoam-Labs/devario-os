#!/usr/bin/env python3
"""Boot the full live filesystem with Venus and require desktop acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import socket
import subprocess
import time


def capture_display(endpoint, destination):
    # GL scanout does not always provide a QMP screendump surface. Capture
    # QEMU's host presentation through a private local VNC connection.
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(15)
        connection.connect(str(endpoint))

        def read(size):
            data = bytearray()
            while len(data) < size:
                part = connection.recv(size - len(data))
                if not part:
                    raise RuntimeError('QEMU display disconnected')
                data.extend(part)
            return bytes(data)

        if read(12) != b'RFB 003.008\n':
            raise RuntimeError('unexpected QEMU VNC protocol')
        connection.sendall(b'RFB 003.008\n')
        if 1 not in read(read(1)[0]):
            raise RuntimeError('local VNC authentication is unavailable')
        connection.sendall(b'\x01')
        if read(4) != bytes(4):
            raise RuntimeError('local VNC handshake failed')
        connection.sendall(b'\x01')
        width, height = struct.unpack('>HH', read(4))
        read(16)
        read(struct.unpack('>I', read(4))[0])
        connection.sendall(bytes(4) + struct.pack('>BBBBHHHBBBxxx',
                                                32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
        connection.sendall(struct.pack('>BBHi', 2, 0, 1, 0))
        connection.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, width, height))
        pixels = bytearray(width * height * 3)
        while True:
            message = read(1)[0]
            if message == 0:
                read(1)
                count = struct.unpack('>H', read(2))[0]
                if not count:
                    raise RuntimeError('QEMU returned an empty display update')
                for _ in range(count):
                    x, y, w, h, encoding = struct.unpack('>HHHHi', read(12))
                    if encoding != 0 or x + w > width or y + h > height:
                        raise RuntimeError('unexpected QEMU display rectangle')
                    raw = read(w * h * 4)
                    for row in range(h):
                        for col in range(w):
                            source = 4 * (row * w + col)
                            target = 3 * ((y + row) * width + x + col)
                            pixels[target:target + 3] = raw[source:source + 3][::-1]
                break
            if message == 2:  # bell
                continue
            if message == 3:  # server clipboard; ignore its contents
                read(3)
                read(struct.unpack('>I', read(4))[0])
                continue
            raise RuntimeError(f'unexpected QEMU display message {message}')
        destination.write_bytes(f'P6\n{width} {height}\n255\n'.encode() + pixels)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iso', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='new directory for retained evidence')
    parser.add_argument('--phase', choices=['live', 'greeter'], default='live')
    parser.add_argument('--firmware', choices=['bios', 'uefi'], default='uefi')
    parser.add_argument('--render-node', type=Path)
    parser.add_argument('--timeout', type=int, default=360)
    args = parser.parse_args()
    image = args.iso.resolve(strict=True)
    output = args.output.resolve()
    if args.timeout < 1:
        parser.error('--timeout must be positive')
    if output.exists():
        parser.error('--output must be a new directory')
    subprocess.run(['bash', '-c', 'source "$1"; devario_qemu_check_venus',
                    'venus-check', str(Path(__file__).parent / 'lib/qemu-graphics.sh')], check=True)
    output.mkdir(parents=True)
    (output / 'request.txt').write_text(f'phase={args.phase}\n')
    # Extract the exact candidate's boot assets. This tests the full live
    # filesystem and session; the BIOS/UEFI bootloader chain has separate tests.
    subprocess.run(['xorriso', '-osirrox', 'on', '-indev', str(image), '-extract',
                    '/devario/boot/x86_64', str(output / 'boot')],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    pvd = subprocess.check_output(['xorriso', '-indev', str(image), '-pvd_info'],
                                  stderr=subprocess.DEVNULL, text=True)
    label = next(line.split(':', 1)[1].strip().strip("'")
                 for line in pvd.splitlines() if line.startswith('Volume Id'))
    monitor = output / 'qmp.sock'
    display_endpoint = output / 'vnc.sock'
    if len(str(monitor).encode()) > 100:
        parser.error('--output path is too long for the QEMU monitor socket')
    display = 'egl-headless'
    if args.render_node:
        display += f',rendernode={args.render_node.resolve(strict=True)}'
    accelerator = 'kvm'
    if 'GenuineIntel' in Path('/proc/cpuinfo').read_text():
        accelerator += ',honor-guest-pat=on'
    command = [
        'qemu-system-x86_64', '-name', f'devario-desktop-{args.phase}',
        '-machine', 'q35,memory-backend=desktop-ram', '-accel', accelerator, '-cpu', 'host',
        '-m', '6G', '-smp', '4', '-object', 'memory-backend-memfd,id=desktop-ram,size=6G,share=on',
        '-device', 'virtio-vga-gl,hostmem=4G,blob=true,venus=true', '-display', display,
        '-device', 'qemu-xhci', '-device', 'usb-tablet', '-nic', 'user,model=virtio-net-pci',
        '-serial', f'file:{output / "serial.log"}', '-monitor', 'none',
        '-qmp', f'unix:{monitor},server=on,wait=off',
        '-vnc', f'unix:{display_endpoint}', '-no-reboot',
        '-fw_cfg', f'name=opt/org.devario/desktop,file={output / "request.txt"}',
        '-drive', f'file={image},media=cdrom,readonly=on',
        '-kernel', str(output / 'boot/vmlinuz-linux-devario'),
        '-initrd', str(output / 'boot/initramfs-linux-devario.img'),
        '-append', f'root=live:LABEL={label} rd.live.dir=devario/x86_64 '
                   'rd.live.squashimg=airootfs.sfs rd.overlay=1 console=ttyS0 rd.shell=0 panic=1',
    ]
    if args.firmware == 'uefi':
        for directory in ('/usr/share/edk2/x64', '/usr/share/edk2/ovmf', '/usr/share/OVMF'):
            code, variables = Path(directory) / 'OVMF_CODE.4m.fd', Path(directory) / 'OVMF_VARS.4m.fd'
            if code.is_file() and variables.is_file():
                shutil.copyfile(variables, output / 'OVMF_VARS.fd')
                command += ['-drive', f'if=pflash,format=raw,readonly=on,file={code}',
                            '-drive', f'if=pflash,format=raw,file={output / "OVMF_VARS.fd"}']
                break
        else:
            raise RuntimeError('OVMF firmware is unavailable')
    (output / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    expected = f'DEVARIO_DESKTOP:PASS phase={args.phase}'
    captured = False

    with (output / 'qemu.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + args.timeout
        try:
            while process.poll() is None:
                serial = output / 'serial.log'
                text = serial.read_text(errors='replace') if serial.exists() else ''
                if expected in text and not captured:
                    # The shell process can appear before its first frame.
                    time.sleep(3)
                    capture_display(display_endpoint, output / 'desktop.ppm')
                    captured = True
                if time.monotonic() >= deadline:
                    raise RuntimeError(f'desktop acceptance timed out after {args.timeout} seconds')
                time.sleep(1)
            text = (output / 'serial.log').read_text(errors='replace')
            if process.returncode != 0 or not captured or expected not in text or 'DEVARIO_DESKTOP:FAIL' in text:
                raise RuntimeError(f'desktop acceptance failed (QEMU exit {process.returncode}); see {output}')
        finally:
            if process.poll() is None:
                if not captured:
                    try:
                        capture_display(display_endpoint, output / 'desktop.ppm')
                    except (OSError, RuntimeError):
                        pass
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            text = (output / 'serial.log').read_text(errors='replace')
            guest_passed = expected in text and 'DEVARIO_DESKTOP:FAIL' not in text
            with image.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            result = {'outcome': 'pass' if guest_passed and captured and process.returncode == 0 else 'fail',
                      'guestOutcome': 'pass' if guest_passed else 'fail',
                      'qemuExitCode': process.returncode, 'displayCaptured': captured,
                      'phase': args.phase, 'firmware': args.firmware,
                      'bootMethod': 'direct-kernel', 'iso': str(image),
                      'isoSha256': digest, 'marker': expected}
            (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'Desktop acceptance passed: {output}')


if __name__ == '__main__':
    main()
