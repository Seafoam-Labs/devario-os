#!/usr/bin/env python3
"""Validate signed-repository record handling without network access."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("stage_core", Path(__file__).resolve().parents[1] / "scripts/stage-core-repository.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
audit_spec = importlib.util.spec_from_file_location("dependency_audit", Path(__file__).resolve().parents[1] / "scripts/audit-iso-repositories.py")
dependency_audit = importlib.util.module_from_spec(audit_spec)
audit_spec.loader.exec_module(dependency_audit)


class RepositoryRecordsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def database(self, filename="probe-1-1-any.pkg.tar.zst", duplicate=False):
        output = self.root / "repo.db"
        row = f"%NAME%\nprobe\n\n%VERSION%\n1-1\n\n%ARCH%\nany\n\n%FILENAME%\n{filename}\n\n%CSIZE%\n3\n\n%SHA256SUM%\n{'a' * 64}\n"
        with tarfile.open(output, "w:gz") as archive:
            for name in (["probe-1-1/desc", "second/desc"] if duplicate else ["probe-1-1/desc"]):
                entry = tarfile.TarInfo(name)
                entry.size = len(row)
                archive.addfile(entry, io.BytesIO(row.encode()))
        return output

    def test_reads_metadata_without_rewriting_archive(self):
        path = self.database()
        before = path.read_bytes()
        self.assertEqual(stage.records(path)["probe"][3], "probe-1-1-any.pkg.tar.zst")
        self.assertEqual(before, path.read_bytes())

    def test_rejects_traversal_filename(self):
        with self.assertRaisesRegex(ValueError, "unsafe"):
            stage.records(self.database("../probe.pkg.tar.zst"))

    def test_rejects_duplicate_packages(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            stage.records(self.database(duplicate=True))

    def test_cache_checks_content_and_size(self):
        path = self.root / "package"
        path.write_bytes(b"one")
        digest = hashlib.sha256(b"one").hexdigest()
        self.assertTrue(stage.matches(path, "3", digest))
        path.write_bytes(b"two")
        self.assertFalse(stage.matches(path, "3", digest))

    def test_explicit_kernel_provider_precedes_unrequested_alternative(self):
        def package(name, depends=(), provides=()):
            return dict(name=name, version="1", depends=depends, provides=provides)
        selected, missing = dependency_audit.resolve(["devario-dracut", "linux"], [
            package("dracut-git", provides=["initramfs"]),
            package("devario-dracut", provides=["initramfs"]),
            package("linux", depends=["initramfs"])])
        self.assertFalse(missing)
        self.assertEqual(set(selected), {"devario-dracut", "linux"})

    def test_literal_zlib_precedes_earlier_unversioned_provider(self):
        packages = [
            dict(name="zlib-ng-compat", version="2.3.3-1", depends=[], provides=["zlib", "libz.so"]),
            dict(name="zlib", version="1:1.3.2-4", depends=[], provides=["libz.so"]),
            dict(name="libarchive", version="3.8.10-1", depends=["libz.so", "zlib>=1.2.1"], provides=[]),
        ]
        for dependencies in (["libz.so", "zlib>=1.2.1"], ["zlib>=1.2.1", "libz.so"]):
            packages[-1]["depends"] = dependencies
            for ordered in (packages, list(reversed(packages))):
                with self.subTest(order=[p["name"] for p in ordered], dependencies=dependencies):
                    selected, missing = dependency_audit.resolve(["libarchive"], ordered)
                    self.assertFalse(missing)
                    self.assertEqual(set(selected), {"libarchive", "zlib"})


if __name__ == "__main__":
    unittest.main()
