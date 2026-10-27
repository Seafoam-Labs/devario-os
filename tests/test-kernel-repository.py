#!/usr/bin/env python3
"""Exercise repository-selected kernels without compiling or installing them."""
import importlib.util
import io
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "kernel_check", Path(__file__).resolve().parents[1] / "scripts/validate-kernel-packages.py")
kernel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kernel)


def archive(path, files):
    with tarfile.open(path, "w:gz") as output:
        for name, content in files.items():
            data = content.encode()
            member = tarfile.TarInfo(name)
            member.size = len(data)
            output.addfile(member, io.BytesIO(data))


@unittest.skipUnless(shutil.which("bsdtar"), "bsdtar is required to inspect packages")
class RepositoryKernelTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = Path(directory.name)

    def snapshot(self, version="9.8.7-4.2", headers_version=None, release="9.8.7-custom",
                 headers_release=None, config=None, boot_metadata=None, pkgbase=False,
                 metadata_version=None, missing_headers=False, missing_image=False):
        headers_version = headers_version or version
        tree = f"usr/lib/modules/{release}"
        config = config if config is not None else (
            "CONFIG_BLK_DEV_INITRD=y\nCONFIG_EFI_STUB=y\nCONFIG_SQUASHFS=m\n"
            "CONFIG_OVERLAY_FS=y\nCONFIG_BLK_DEV_LOOP=m\n")
        files = {tree + "/vmlinuz": "kernel",
                 tree + "/devario-kernel": boot_metadata if boot_metadata is not None else
                 f"version={release}\nimage=vmlinuz\nid=linux-devario\n"}
        if missing_image:
            del files[tree + "/vmlinuz"]
        if pkgbase:
            del files[tree + "/devario-kernel"]
            files[tree + "/pkgbase"] = "linux-devario\n"
        database = {}
        for name, selected_version, payload in (
            ("linux-devario", version, files),
            ("linux-devario-headers", headers_version, {
                tree + "/build/include/config/kernel.release": headers_release or release,
                tree + "/build/.config": config})):
            if missing_headers and name.endswith("-headers"):
                continue
            filename = f"{name}-{selected_version}-x86_64.pkg.tar.zst"
            payload[".PKGINFO"] = (f"pkgname = {name}\npkgver = {metadata_version or selected_version}\n"
                                   "arch = x86_64\n")
            archive(self.repo / filename, payload)
            database[f"{name}/desc"] = (
                f"%NAME%\n{name}\n\n%VERSION%\n{selected_version}\n\n%FILENAME%\n{filename}\n")
        archive(self.repo / "devario-core.db", database)

    def test_accepts_repository_versions_and_epochs(self):
        for version in ("7.3.0-7.1", "2:9.8.7-12"):
            with self.subTest(version=version):
                self.snapshot(version=version)
                self.assertEqual(kernel.validate(self.repo), (version, "9.8.7-custom"))

    def test_accepts_pkgbase_compatibility_metadata(self):
        self.snapshot(pkgbase=True)
        kernel.validate(self.repo)

    def test_rejects_incompatible_or_incomplete_snapshots(self):
        cases = [
            ({"headers_version": "9.8.7-5"}, "versions differ"),
            ({"headers_release": "different-kernel"}, "release does not match"),
            ({"metadata_version": "old-package"}, "metadata differs"),
            ({"missing_headers": True}, "exactly one linux-devario-headers"),
            ({"missing_image": True}, "exactly one module tree"),
            ({"boot_metadata": "version=wrong\nimage=vmlinuz\nid=linux-devario\n"}, "boot metadata"),
            ({"config": "CONFIG_BLK_DEV_INITRD=y\n"}, "live boot support"),
        ]
        for options, error in cases:
            with self.subTest(options=options):
                self.snapshot(**options)
                with self.assertRaisesRegex(ValueError, error):
                    kernel.validate(self.repo)


if __name__ == "__main__":
    unittest.main()
