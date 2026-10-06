#!/usr/bin/env python3
"""Exercise QEMU launch decisions without GPU access or a running VM."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]


@unittest.skipIf(os.geteuid() == 0, 'The helper deliberately rejects root')
class QemuGraphicsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='devario-qemu-graphics-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.iso = self.root / 'test.iso'
        self.iso.touch()
        firmware = self.root / 'firmware'
        firmware.mkdir()
        (firmware / 'OVMF_CODE.4m.fd').write_bytes(b'fixture')
        (firmware / 'OVMF_VARS.4m.fd').write_bytes(b'fixture')
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        DISPLAY=':test', DEVARIO_QEMU_STATE_DIR=str(self.root / 'vm'),
                        DEVARIO_QEMU_MEMORY='1024', DEVARIO_QEMU_DISK_SIZE='1G',
                        DEVARIO_QEMU_FIRMWARE_DIR=str(firmware))
        self.tool('qemu-img', 'if [ "$1" = create ]; then touch "$4"; fi\n')
        self.tool('qemu-system-x86_64', '''
if [ "${MOCK_VENUS:-yes}" = yes ]; then echo '  venus=<bool>'; fi
echo '  blob=<bool>'
echo '  hostmem=<size>'
''')
        self.tool('vulkaninfo', '''
if [ "${MOCK_VULKAN:-yes}" != yes ]; then echo 'no Vulkan device'; exit 1; fi
echo 'deviceName = test host GPU'
''')

    def tool(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + body)
        path.chmod(0o755)

    def launch(self, *args, **environment):
        return subprocess.run(['bash', str(PROJECT / 'scripts/setup-qemu.sh'),
                               '--software', '--iso', str(self.iso), '--dry-run', *args],
                              env=dict(self.env, **environment), capture_output=True, text=True)

    def test_desktop_requests_venus_and_matching_shared_ram(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('venus=true', result.stdout)
        self.assertIn('blob=true', result.stdout)
        self.assertIn('hostmem=4G', result.stdout)
        self.assertIn('size=1024M', result.stdout)
        self.assertIn('share=on', result.stdout)

    def test_missing_venus_stops_before_creating_vm(self):
        result = self.launch(MOCK_VENUS='no')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('lacks venus', result.stderr)
        self.assertFalse((self.root / 'vm').exists())

    def test_host_without_vulkan_stops_before_creating_vm(self):
        result = self.launch(MOCK_VULKAN='no')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Host Vulkan enumeration failed', result.stderr)
        self.assertFalse((self.root / 'vm').exists())

    def test_console_mode_does_not_require_vulkan(self):
        result = self.launch('--no-gl', MOCK_VULKAN='no', MOCK_VENUS='no')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('console only', result.stderr)
        self.assertNotIn('venus=true', result.stdout)

    def test_invalid_host_memory_is_rejected(self):
        result = self.launch(DEVARIO_QEMU_HOSTMEM='4')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('DEVARIO_QEMU_HOSTMEM', result.stderr)


if __name__ == '__main__':
    unittest.main()
