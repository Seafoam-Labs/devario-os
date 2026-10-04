#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise real Shelly/chroot preflight against a built image, without a GPU.

Usage: python3 tests/test-nvidia-preflight-image.py IMAGE_ROOT
Requires bubblewrap and enabled user namespaces on the test host. IMAGE_ROOT
is the assembled image/root directory; it is always mounted read-only. The
current profile's helper is mounted into both the live and pristine roots.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
PROFILE = Path(os.environ.get("DEVARIO_PROFILE_DIR", PROJECT / "iso"))
HELPER = "/usr/lib/devario/configure-target-nvidia"
SOURCE = "/run/devario/install-root"
DEVICE = {"address": "0000:01:00.0", "ids": ["1e04", "10de", "0000"]}

# These assertions run in the simulated live session, outside the helper's
# namespace. Check cleanup on failure as well as success, and after a retry.
PROBE = '''
import os
from pathlib import Path
import subprocess
import sys
source = Path("/run/devario/install-root")
mounts = Path("/proc/self/mountinfo")
before = mounts.read_text()
payload = sys.stdin.read()
def require(condition, message):
    if not condition:
        print(message, file=sys.stderr)
        sys.exit(99)  # Distinct from an expected helper failure (exit 1).
for attempt in range(2):
    result = subprocess.run(sys.argv[1:], input=payload, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, end="", flush=True)
    require(mounts.read_text() == before, "Preflight leaked mounts into the live session")
    if source.exists():
        require(os.statvfs(source).f_flag & os.ST_RDONLY, "Installation source became writable")
        require(not (source / "proc/self").exists(), "Preflight left /proc mounted in source")
sys.exit(result.returncode)
'''


class ImagePreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="devario-nvidia-image-test-")
        self.addCleanup(self.temporary.cleanup)
        self.fixtures = Path(self.temporary.name)
        self.pci = self.fixtures / "pci"
        self.pci.mkdir()
        self.empty = self.fixtures / "empty"
        self.empty.mkdir()

    def gpu(self, device="1e04"):
        directory = self.pci / DEVICE["address"]
        directory.mkdir()
        for field, value in {"vendor": "10de", "class": "030000", "device": device,
                             "subsystem_vendor": "10de", "subsystem_device": "0000"}.items():
            (directory / field).write_text(f"0x{value}\n")

    def run_helper(self, *, bare_chroot=False, source=True, missing_firmware=False,
                   writable_home=False):
        command = [
            "bwrap", "--unshare-user", "--unshare-pid", "--uid", "0", "--gid", "0",
            "--cap-add", "CAP_SYS_ADMIN", "--cap-add", "CAP_SYS_CHROOT", "--die-with-parent",
            "--ro-bind", str(IMAGE_ROOT), "/", "--proc", "/proc", "--dev", "/dev",
            "--tmpfs", "/run", "--ro-bind", str(PROFILE / "airootfs" / HELPER[1:]), HELPER,
            "--ro-bind", str(self.pci), "/run/test-pci",
        ]
        if source:
            command += ["--ro-bind", str(IMAGE_ROOT), SOURCE,
                        "--ro-bind", str(PROFILE / "airootfs" / HELPER[1:]), SOURCE + HELPER]
            command += (["--tmpfs", SOURCE + "/root"] if writable_home else
                        ["--ro-bind", str(self.empty), SOURCE + "/root"])
        if missing_firmware:
            version = json.loads((IMAGE_ROOT / "usr/share/devario/nvidia-supported-gpus.json")
                                 .read_text())["driverVersion"]
            command += ["--ro-bind", str(self.empty), SOURCE + f"/usr/lib/firmware/nvidia/{version}"]
        command += ["--clearenv", "--setenv", "HOME", "/root", "--setenv", "PATH", "/usr/bin:/bin",
                    "--setenv", "DEVARIO_PCI_DEVICES_ROOT", "/run/test-pci"]
        if not bare_chroot:
            # A root GUI can inherit the desktop user's XDG paths. None may
            # redirect Shelly state back into the read-only installation tree.
            for variable in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"):
                command += ["--setenv", variable, "/etc/unwritable-desktop-state"]
        command += ["--chdir", "/", "python3", "-c", PROBE]
        command += (["chroot", SOURCE, HELPER, "--check-payload"] if bare_chroot
                    else [HELPER, "--preflight"])
        return subprocess.run(command, input=json.dumps([DEVICE]), text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)

    def test_bare_chroot_reproduces_read_only_failure(self):
        result = self.run_helper(bare_chroot=True)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("ReadOnlyFileSystem", result.stdout)

    def test_supported_gpu_passes_with_real_shelly(self):
        self.gpu()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout.count("verified offline payload for target kernel"), 2)

    def test_writable_home_without_proc_reproduces_init_failure(self):
        result = self.run_helper(bare_chroot=True, writable_home=True)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("InitFailed", result.stdout)

    def test_missing_firmware_reports_cause_and_cleans_up(self):
        self.gpu()
        result = self.run_helper(missing_firmware=True)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Missing NVIDIA firmware", result.stdout)
        self.assertIn("Pristine NVIDIA payload check failed", result.stdout)

    def test_unsupported_gpu_still_fails_clearly(self):
        self.gpu("1b80")
        result = self.run_helper()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Unsupported NVIDIA GPU", result.stdout)

    def test_no_nvidia_needs_no_pristine_root(self):
        result = self.run_helper(source=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("no NVIDIA display controllers", result.stdout)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image_root", type=Path)
    arguments = parser.parse_args()
    IMAGE_ROOT = arguments.image_root.resolve(strict=True)
    if not (IMAGE_ROOT / "usr/bin/shelly").is_file():
        parser.error("IMAGE_ROOT must contain the assembled Devario filesystem and Shelly")
    if not shutil.which("bwrap"):
        parser.error("bubblewrap is required on the test host")
    unittest.main(argv=[sys.argv[0]], verbosity=2)
