#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise /tmp policy using systemctl against disposable roots, never the host."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

import yaml

PROJECT = Path(__file__).resolve().parents[1]
PROFILE = Path(os.environ.get("DEVARIO_PROFILE_DIR", PROJECT / "iso"))
SCRIPT = PROJECT / "scripts/use-disk-tmp.sh"
SYSTEMCTL = shutil.which("systemctl")


class DiskTmpTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="devario-disk-tmp-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.mask = self.root / "etc/systemd/system/tmp.mount"
        self.mask.parent.mkdir(parents=True)
        vendor = self.root / "usr/lib/systemd/system/tmp.mount"
        vendor.parent.mkdir(parents=True)
        vendor.write_text("[Mount]\nWhat=tmpfs\nWhere=/tmp\nType=tmpfs\n")
        self.sentinel = self.root / "tmp/keep-this-build"
        self.sentinel.parent.mkdir(mode=0o1777)
        self.sentinel.write_text("unfinished work")
        self.calls = self.root / "calls"
        self.stub("id", '#!/bin/sh\nprintf "%s\\n" "${TEST_UID:-0}"\n')
        self.stub("findmnt", '''#!/bin/sh
printf '%s\n' "${TEST_MOUNTS-/}"
exit "${TEST_FINDMNT_STATUS:-0}"
''')
        # Guard against any future live mount operation before invoking systemctl.
        self.stub("systemctl", '''#!/bin/sh
printf '%s\n' "$*" >> "$TEST_CALLS"
[ "$#" -eq 2 ] && [ "$1" = mask ] && [ "$2" = tmp.mount ] || exit 99
exec "$TEST_SYSTEMCTL" --root="$TEST_ROOT" "$@"
''')
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        TEST_ROOT=str(self.root), TEST_CALLS=str(self.calls),
                        TEST_SYSTEMCTL=SYSTEMCTL)

    def stub(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_script(self, *args, **env):
        return subprocess.run(["bash", str(SCRIPT), *args], env=dict(self.env, **env),
                              capture_output=True, text=True, timeout=10)

    def test_masks_next_boot_idempotently_and_preserves_files(self):
        for _ in range(2):
            result = self.run_script()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(os.readlink(self.mask), "/dev/null")
            self.assertEqual(self.sentinel.read_text(), "unfinished work")
            self.assertIn("Before rebooting", result.stdout)
        self.assertEqual(self.calls.read_text().splitlines(), ["mask tmp.mount"] * 2)

    def test_explicit_fstab_mount_is_not_overridden(self):
        result = self.run_script(TEST_MOUNTS="/\n/tmp\n/home")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fstab explicitly mounts /tmp", result.stderr)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.mask.is_symlink())

    def test_custom_unit_is_not_overwritten(self):
        self.mask.write_text("# administrator's custom mount\n")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.mask.read_text(), "# administrator's custom mount\n")
        self.assertNotIn("configured for the next boot", result.stdout)

    def test_requires_root_but_help_does_not(self):
        result = self.run_script(TEST_UID="1000")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sudo", result.stderr)
        result = self.run_script("--help", TEST_UID="1000")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.calls.exists())

    def test_empty_fstab_and_inspection_failure(self):
        result = self.run_script(TEST_MOUNTS="", TEST_FINDMNT_STATUS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.mask.unlink()
        self.calls.unlink()
        result = self.run_script(TEST_FINDMNT_STATUS="2")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.mask.is_symlink())

    def test_installer_masks_only_target_after_fstab(self):
        modules = PROFILE / "airootfs/etc/calamares/modules"
        prepare = yaml.safe_load((modules / "prepare_target.conf").read_text())
        self.assertFalse(prepare["dontChroot"])
        command = next(command for command in prepare["script"] if "mask tmp.mount" in command)
        args = shlex.split(command)
        self.assertEqual(args, ["systemctl", "--root=/", "mask", "tmp.mount"])
        args[0] = SYSTEMCTL
        args[1] = f"--root={self.root}"
        subprocess.run(args, check=True, capture_output=True, text=True)
        self.assertEqual(os.readlink(self.mask), "/dev/null")
        self.assertEqual(self.sentinel.read_text(), "unfinished work")
        settings = yaml.safe_load((modules.parent / "settings.conf").read_text())
        sequence = next(step["exec"] for step in settings["sequence"] if "exec" in step)
        self.assertLess(sequence.index("fstab"), sequence.index("shellprocess@prepare_target"))
        fstab = yaml.safe_load((modules / "fstab.conf").read_text())
        self.assertTrue(all(not options["tmpfs"] for options in fstab["tmpOptions"].values()))


if __name__ == "__main__":
    unittest.main()
