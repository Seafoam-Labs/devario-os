#!/usr/bin/env python3
"""Exercise offline installation, isolation, and fail-closed environment reuse."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
PREPARE = PROJECT / "scripts/prepare-validation-env.py"


class ValidationEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="devario-python-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / "cache"

    def command(self, *args, cache=None):
        return subprocess.run([sys.executable, "-I", "-B", str(PREPARE),
                               "--cache-dir", str(cache or self.cache), *map(str, args)],
                              capture_output=True, text=True)

    def wheels(self):
        source = os.environ.get("DEVARIO_VALIDATION_TEST_WHEELHOUSE")
        if not source:
            self.skipTest("set DEVARIO_VALIDATION_TEST_WHEELHOUSE to a prepared wheel cache")
        return Path(source)

    def test_check_never_creates_environment(self):
        result = self.command("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing or stale", result.stderr)
        self.assertFalse(self.cache.exists())

    def test_offline_missing_wheelhouse(self):
        result = self.command("--offline", "--wheelhouse", self.root / "absent")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Offline wheelhouse does not exist", result.stderr)
        self.assertFalse((self.cache / "envs").exists())

    def test_offline_install_and_read_only_reuse(self):
        result = self.command("--offline", "--wheelhouse", self.wheels())
        self.assertEqual(result.returncode, 0, result.stderr)
        environment = Path(result.stdout.strip())
        def snapshot():
            return {str(p.relative_to(self.cache)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in self.cache.rglob("*") if p.is_file() and not p.is_symlink()}
        before = snapshot()
        result = self.command("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before, snapshot(), "checking an attested environment must not change its files")
        state = environment / "devario-validation.json"
        data = json.loads(state.read_text())
        data["requirementsSha256"] = "0" * 64
        state.write_text(json.dumps(data))
        self.assertNotEqual(self.command("--check").returncode, 0)

    def test_corrupted_wheel_is_rejected(self):
        wheels = self.root / "wheels"
        shutil.copytree(self.wheels(), wheels)
        wheel = next(wheels.glob("attrs-*.whl"))
        with wheel.open("ab") as stream:
            stream.write(b"tampered wheel")
        result = self.command("--offline", "--wheelhouse", wheels)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HASHES", result.stderr.upper())
        self.assertFalse(list((self.cache / "envs").glob("*/devario-validation.json")))

    def test_controlled_activation_cannot_prepare(self):
        env = dict(os.environ, DEVARIO_VALIDATION_CACHE=str(self.cache), DEVARIO_CONTROLLED_NSPAWN="1")
        result = subprocess.run([str(PROJECT / "scripts/with-validation-env.sh"),
                                 "python3", "-c", "raise SystemExit('must not execute')"],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing or stale", result.stderr)
        self.assertFalse(self.cache.exists())


if __name__ == "__main__":
    unittest.main()
