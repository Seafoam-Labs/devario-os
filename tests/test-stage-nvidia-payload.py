#!/usr/bin/env python3
"""Exercise offline driver staging with real package/database archive fixtures."""
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("stage_nvidia", PROJECT / "scripts/stage-nvidia-payload.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
VERSION = "580.196.07"


def archive(path, files):
    with tarfile.open(path, "w:gz") as output:
        for name, text in files.items():
            data = text.encode()
            member = tarfile.TarInfo(name)
            member.size = len(data)
            output.addfile(member, io.BytesIO(data))


class PayloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.repository = root / "repo"
        self.profile = root / "profile"
        self.repository.mkdir()
        self.profile.mkdir()
        (self.profile / "packages.x86_64").write_text("nvidia-open-dkms\nnvidia-utils\ndkms\n")
        self.files = {}
        for name in stage.nvidia.LEGACY_PACKAGES:
            files = {".PKGINFO": f"pkgname = {name}\npkgver = {VERSION}-1\n"}
            if name.endswith("-dkms"):
                files[f"usr/src/nvidia-{VERSION}/dkms.conf"] = "source"
            else:
                files["usr/share/doc/nvidia/html/supportedchips.html"] = (
                    f'the {VERSION} driver <tr id="devid1B80"></tr>'
                    'Below are the legacy GPUs <tr id="devid0FC0"></tr>')
                files["usr/share/doc/nvidia/supported-gpus.json"] = json.dumps({"chips": [
                    {"devid": "0x1B80", "features": []},
                    {"devid": "0x0FC0", "features": [], "legacybranch": "470.xx"},
                    {"devid": "0x2B85", "features": ["kernelopen"]},
                ]})
                for firmware in stage.nvidia.FIRMWARE[:2]:
                    files[f"usr/lib/firmware/nvidia/{VERSION}/{firmware}"] = "firmware"
            self.files[name] = files
        self.packages()
        self.database()

    def packages(self):
        for name, files in self.files.items():
            path = self.repository / f"{name}-{VERSION}-1-x86_64.pkg.tar.zst"
            archive(path, files)
            Path(str(path) + ".sig").write_bytes(b"signature fixture")

    def database(self, extra_dependency=None):
        files = {}
        for name in (*stage.nvidia.OPEN_PACKAGES, *stage.nvidia.LEGACY_PACKAGES, "dkms"):
            text = f"%NAME%\n{name}\n\n%VERSION%\n{VERSION}-1\n\n%FILENAME%\n{name}-{VERSION}-1-x86_64.pkg.tar.zst\n\n"
            if name == "nvidia-580xx-dkms":
                text += f"%DEPENDS%\nnvidia-580xx-utils={VERSION}\ndkms\n\n"
            if name == "nvidia-580xx-utils" and extra_dependency:
                text += f"%DEPENDS%\n{extra_dependency}\n\n"
            files[f"{name}/desc"] = text
        archive(self.repository / "devario-core.db", files)

    def test_stages_signed_archives_and_support_for_offline_selection(self):
        stage.stage(self.repository, self.profile)
        root = self.profile / "airootfs"
        destination = root / stage.nvidia.LEGACY_PAYLOAD.relative_to("/")
        support = json.loads((destination / "manifest.json").read_text())
        self.assertEqual(support["pciIds"], ["1b80"])
        self.assertEqual(support["driverVersion"], VERSION)
        paths = stage.nvidia.legacy_archives(root, support)
        self.assertEqual(len(paths), 2)
        self.assertTrue(all(Path(path).is_file() for path in paths))
        self.assertFalse((root / "usr/src").exists())

    def test_requires_matching_versions_and_signed_payloads(self):
        self.files["nvidia-580xx-utils"][".PKGINFO"] = "pkgname = nvidia-580xx-utils\npkgver = 580.100.01-1\n"
        self.packages()
        with self.assertRaisesRegex(ValueError, "versions differ"):
            stage.stage(self.repository, self.profile)

    def test_requires_signature(self):
        next(self.repository.glob("*.sig")).unlink()
        with self.assertRaises(FileNotFoundError):
            stage.stage(self.repository, self.profile)

    def test_requires_sources_and_firmware(self):
        for name, member in (("nvidia-580xx-dkms", f"usr/src/nvidia-{VERSION}/dkms.conf"),
                             ("nvidia-580xx-utils", f"usr/lib/firmware/nvidia/{VERSION}/gsp_tu10x.bin")):
            with self.subTest(member=member):
                saved = self.files[name].pop(member)
                self.packages()
                with self.assertRaises(ValueError):
                    stage.stage(self.repository, self.profile)
                self.files[name][member] = saved

    def test_missing_dependency_fails_build(self):
        self.database(extra_dependency="missing-library")
        with self.assertRaisesRegex(ValueError, "offline dependencies are incomplete"):
            stage.stage(self.repository, self.profile)


if __name__ == "__main__":
    unittest.main()
