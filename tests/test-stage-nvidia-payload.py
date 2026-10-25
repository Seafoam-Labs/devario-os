#!/usr/bin/env python3
"""Exercise offline driver staging with real package/database archive fixtures."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("stage_nvidia", PROJECT / "scripts/stage-nvidia-payload.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
VERSION = "580.178.04"
PACKAGE_VERSION = f"1:{VERSION}-4"
OPEN_VERSION = "615.78.08"
OPEN_README = f"""NVIDIA open kernel modules, version {OPEN_VERSION}.
## Compatible GPUs
| GPU | PCI ID |
| Example | 2560 |
| Restricted | 1E78 10DE 13D8 |
## Other
"""


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
            files = {".PKGINFO": f"pkgname = {name}\npkgver = {PACKAGE_VERSION}\n"}
            if name.endswith("-dkms"):
                files[f"usr/src/nvidia-{VERSION}/dkms.conf"] = "source"
            elif name == "nvidia-580xx-utils":
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
        self.files["opencl-nvidia-580xx"].update({f"usr/lib/libnvidia-opencl.so.{VERSION}": "library",
                                                  "etc/OpenCL/vendors/nvidia.icd": "libnvidia-opencl.so.1"})
        self.files["lib32-nvidia-580xx-utils"].update({f"usr/lib32/libGLX_nvidia.so.{VERSION}": "library",
                                                      f"usr/lib32/libEGL_nvidia.so.{VERSION}": "library"})
        self.files["lib32-opencl-nvidia-580xx"][f"usr/lib32/libnvidia-opencl.so.{VERSION}"] = "library"
        for name in stage.nvidia.OPEN_PACKAGES:
            self.files[name] = {".PKGINFO": f"pkgname = {name}\npkgver = {OPEN_VERSION}-1\n"}
        self.files["nvidia-open-dkms"][f"usr/src/nvidia-{OPEN_VERSION}/README.md"] = OPEN_README
        self.packages()
        self.database()

    def packages(self):
        for name, files in self.files.items():
            version = f"{OPEN_VERSION}-1" if name in stage.nvidia.OPEN_PACKAGES else PACKAGE_VERSION
            path = self.repository / f"{name}-{version}-x86_64.pkg.tar.zst"
            archive(path, files)
            Path(str(path) + ".sig").write_bytes(b"signature fixture")

    def database(self, extra_dependency=None, versions=None, omit=()):
        files = {}
        for name in (*stage.nvidia.OPEN_PACKAGES, *stage.nvidia.LEGACY_PACKAGES, "dkms"):
            if name in omit:
                continue
            version = f"{OPEN_VERSION}-1" if name in stage.nvidia.OPEN_PACKAGES else PACKAGE_VERSION
            metadata_version = (versions or {}).get(name, version)
            text = f"%NAME%\n{name}\n\n%VERSION%\n{metadata_version}\n\n%FILENAME%\n{name}-{version}-x86_64.pkg.tar.zst\n\n"
            if name == "nvidia-580xx-dkms":
                text += f"%DEPENDS%\nnvidia-580xx-utils={VERSION}\ndkms\n\n"
            if name == "nvidia-580xx-utils":
                deps = [f"{p}=1:{VERSION}" for p in stage.nvidia.LEGACY_PACKAGES[2:]]
                if extra_dependency:
                    deps.append(extra_dependency)
                text += "%DEPENDS%\n" + "\n".join(deps) + "\n\n"
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
        self.assertEqual(len(paths), 5)
        self.assertTrue(all(Path(path).is_file() for path in paths))
        self.assertFalse((root / "usr/src").exists())

    def test_requires_matching_versions_and_signed_payloads(self):
        self.files["nvidia-580xx-utils"][".PKGINFO"] = "pkgname = nvidia-580xx-utils\npkgver = 580.100.01-1\n"
        self.packages()
        self.database(versions={"nvidia-580xx-utils": "580.100.01-1"})
        with self.assertRaisesRegex(ValueError, "versions differ"):
            stage.stage(self.repository, self.profile)

    def test_missing_multilib_or_opencl_package_fails_build(self):
        for name in stage.nvidia.LEGACY_PACKAGES[2:]:
            with self.subTest(name=name):
                self.database(omit=(name,))
                with self.assertRaisesRegex(ValueError, f"exactly one signed {name}"):
                    stage.stage(self.repository, self.profile)

    def test_multilib_version_must_match_driver(self):
        name = "lib32-nvidia-580xx-utils"
        self.files[name][".PKGINFO"] = f"pkgname = {name}\npkgver = 580.196.07-1\n"
        self.packages()
        self.database(versions={name: "580.196.07-1"})
        with self.assertRaisesRegex(ValueError, "versions differ"):
            stage.stage(self.repository, self.profile)

    def test_legacy_metadata_must_match_repository(self):
        self.database(versions={"lib32-opencl-nvidia-580xx": "1:580.178.04-99"})
        with self.assertRaisesRegex(ValueError, "metadata differs from repository"):
            stage.stage(self.repository, self.profile)

    def test_multilib_libraries_and_opencl_icd_are_required(self):
        for name, member in (("lib32-nvidia-580xx-utils", f"usr/lib32/libGLX_nvidia.so.{VERSION}"),
                             ("lib32-opencl-nvidia-580xx", f"usr/lib32/libnvidia-opencl.so.{VERSION}"),
                             ("opencl-nvidia-580xx", "etc/OpenCL/vendors/nvidia.icd")):
            with self.subTest(name=name):
                saved = self.files[name].pop(member)
                self.packages()
                with self.assertRaisesRegex(ValueError, "missing graphics/OpenCL"):
                    stage.stage(self.repository, self.profile)
                self.files[name][member] = saved

    def test_requires_signature(self):
        next(self.repository.glob("nvidia-580xx-*.sig")).unlink()
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

    def test_replaces_stale_table_and_passes_installer_preflight(self):
        root = self.profile / "airootfs"
        table = root / stage.nvidia.SUPPORT.relative_to("/")
        table.parent.mkdir(parents=True)
        table.write_text(json.dumps({"driverVersion": "615.71.09", "pciIds": ["2560"]}))
        stage.stage(self.repository, self.profile)
        support = json.loads(table.read_text())
        self.assertEqual(support["driverVersion"], OPEN_VERSION)
        self.assertEqual(support["pciIds"], ["1e78 10de 13d8", "2560"])
        self.assertEqual(support["sourceSha256"], hashlib.sha256(OPEN_README.encode()).hexdigest())
        kernel = "7.2.7-1-devario"
        files = {f"usr/src/nvidia-{OPEN_VERSION}/dkms.conf": "sources",
                 f"usr/lib/modules/{kernel}/build/Makefile": "headers",
                 f"usr/lib/modules/{kernel}/build/include/config/kernel.release": kernel}
        files.update({f"usr/lib/firmware/nvidia/{OPEN_VERSION}/{name}": "firmware"
                      for name in stage.nvidia.FIRMWARE})
        for name, content in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        packages = {name: "1-1" for name in ("dkms", "gcc", "make", "patch", "linux-devario",
                                             "linux-devario-headers")}
        packages.update({name: f"{OPEN_VERSION}-1" for name in stage.nvidia.OPEN_PACKAGES})
        device = {"address": "0000:01:00.0", "ids": ["2560", "17aa", "3e85"]}
        with patch.object(stage.nvidia, "installed_packages", return_value=packages), \
                patch.object(stage.nvidia, "output", return_value=kernel):
            self.assertEqual(stage.nvidia.check_payload([device], root, preflight=True), (kernel, OPEN_VERSION))
            packages["nvidia-utils"] = "615.71.09-1"
            with self.assertRaisesRegex(RuntimeError, "must be 615.78.08"):
                stage.nvidia.check_payload([device], root, preflight=True)

    def test_open_metadata_must_match_repository(self):
        self.files["nvidia-utils"][".PKGINFO"] = "pkgname = nvidia-utils\npkgver = 615.71.09-1\n"
        self.packages()
        with self.assertRaisesRegex(ValueError, "metadata differs from repository"):
            stage.stage(self.repository, self.profile)

    def test_open_driver_and_libraries_must_match(self):
        packages = stage.audit.records(self.repository / "devario-core.db", "devario-core")
        next(p for p in packages if p["name"] == "nvidia-utils")["version"] = "615.71.09-1"
        self.files["nvidia-utils"][".PKGINFO"] = "pkgname = nvidia-utils\npkgver = 615.71.09-1\n"
        self.packages()
        with self.assertRaisesRegex(ValueError, "versions differ"):
            stage.open_support(self.repository, packages)

    def test_open_support_requires_matching_readme_and_gpu_table(self):
        for readme in (OPEN_README.replace(OPEN_VERSION, "615.71.09"),
                       OPEN_README.replace("## Compatible GPUs", "## Missing"),
                       OPEN_README.split("| GPU", 1)[0]):
            with self.subTest(readme=readme):
                self.files["nvidia-open-dkms"][f"usr/src/nvidia-{OPEN_VERSION}/README.md"] = readme
                self.packages()
                with self.assertRaises(ValueError):
                    stage.stage(self.repository, self.profile)

    def test_open_package_requires_signature(self):
        next(self.repository.glob("nvidia-open-dkms-*.sig")).unlink()
        with self.assertRaisesRegex(ValueError, "Missing NVIDIA package signature"):
            stage.stage(self.repository, self.profile)


if __name__ == "__main__":
    unittest.main()
