#!/usr/bin/env python3
"""Exercise the ISO gate with real ELF GNU property notes, without host flags."""
import io
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]


def elf_with_isa(level):
    # ELF64 executable with one PT_NOTE: GNU_PROPERTY_X86_ISA_1_NEEDED.
    note = struct.pack('<III4sIIII', 4, 16, 5, b'GNU\0', 0xc0008002, 4,
                       (1 << level) - 1, 0)
    identity = b'\x7fELF\x02\x01\x01' + bytes(9)
    header = struct.pack('<16sHHIQQQIHHHHHH', identity, 2, 62, 1, 0, 64, 0, 0,
                         64, 56, 1, 0, 0, 0)
    segment = struct.pack('<IIQQQQQQ', 4, 4, 120, 0, 0, len(note), len(note), 8)
    return header + segment + note


class CalamaresIsaTests(unittest.TestCase):
    def test_archive_gate_checks_executable_and_plugins(self):
        for binary, plugin, accepted in [(3, 3, True), (4, 3, False), (3, 4, False)]:
            with self.subTest(binary=binary, plugin=plugin), tempfile.TemporaryDirectory() as directory:
                archive = Path(directory) / 'calamares.pkg.tar'
                with tarfile.open(archive, 'w') as output:
                    for name, level in [('usr/bin/calamares', binary),
                                        ('usr/lib/calamares/modules/test/libtest.so', plugin)]:
                        payload = elf_with_isa(level)
                        entry = tarfile.TarInfo(name)
                        entry.size = len(payload)
                        output.addfile(entry, io.BytesIO(payload))
                result = subprocess.run(['bash', str(PROJECT / 'scripts/verify-calamares-isa.sh'), str(archive)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)
                if not accepted:
                    self.assertIn('exceeds x86-64-v3', result.stderr)


if __name__ == '__main__':
    unittest.main()
