#!/usr/bin/env python3
"""Exercise core-only provisioning and artifact checks without root or downloads."""
import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("core_builder", PROJECT / "scripts/build-packages-core.py")
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class CoreBuilderTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="devario-core-builder-test-")
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)
        self.args = argparse.Namespace(repo=self.directory / "repo", work=self.directory / "work",
                                       keyring=PROJECT / "packages/devario-keyring", prepare_only=False)
        self.packages = [{"name": name, "version": "1-1"} for name in ("gcc", "glibc", "binutils")]

    def test_dependencies_include_compiler_runtime_and_arch_specific_build_inputs(self):
        result = builder.dependencies({
            "devario-base": "depends = desktop-only",
            "calamares": "depends = ckbcomp\n depends = glibc\n makedepends = qt6-tools\n"
                         "makedepends_x86_64 = ninja\ncheckdepends = check-tool>=2\n"
                         "makedepends_aarch64 = foreign-tool",
        })
        for package in ("gcc", "glibc", "binutils", "qt6-tools", "ninja", "check-tool>=2"):
            self.assertIn(package, result)
        for package in ("desktop-only", "ckbcomp", "foreign-tool", "base-devel", "makepkg"):
            self.assertNotIn(package, result)

    def test_missing_core_dependency_stops_before_privileges(self):
        self.args.repo.mkdir()
        (self.args.repo / "shelly-cli-1-1-x86_64.pkg.tar.zst").touch()
        audit = argparse.Namespace(records=lambda *a: [], resolve=lambda *a: ({}, {"litehtml": ["qt6-tools"]}))
        with patch.object(builder.os, "geteuid", return_value=1000), \
                patch.object(builder.shutil, "which", return_value="/usr/bin/fixture"), \
                patch.object(builder, "verify_repository"), \
                patch.object(builder, "module_from", return_value=audit), \
                patch.object(builder, "run", return_value=subprocess.CompletedProcess([], 0, stdout="")) as run:
            with self.assertRaisesRegex(ValueError, r"litehtml \(required by qt6-tools\)"):
                builder.prepare(self.args)
        self.assertFalse(any(call.args[0] == "sudo" for call in run.call_args_list))
        report = json.loads((self.args.work / "dependency-audit.json").read_text())
        self.assertEqual(report["missing"], {"litehtml": ["qt6-tools"]})
        self.assertFalse(report["complete"])
        self.assertFalse((self.args.work / "root").exists())

    def test_orchestrated_build_uses_noninteractive_sudo(self):
        self.args.repo.mkdir()
        (self.args.repo / "shelly-cli-1-1-x86_64.pkg.tar.zst").touch()
        selected = {name: dict(name=name, version="1-1") for name in ("gcc", "glibc", "binutils", "cmake")}
        audit = argparse.Namespace(records=lambda *a: [], resolve=lambda *a: (selected, {}))
        for noninteractive in ("0", "1"):
            with self.subTest(noninteractive=noninteractive):
                self.args.work = self.directory / ("work-" + noninteractive)
                with patch.dict(os.environ, DEVARIO_SUDO_NONINTERACTIVE=noninteractive), \
                        patch.object(builder.os, "geteuid", return_value=1000), \
                        patch.object(builder.shutil, "which", return_value="/usr/bin/fixture"), \
                        patch.object(builder, "verify_repository"), \
                        patch.object(builder, "verify_artifacts"), \
                        patch.object(builder, "module_from", return_value=audit), \
                        patch.object(builder, "run", return_value=subprocess.CompletedProcess([], 0, stdout="")) as run:
                    builder.prepare(self.args)
                elevation = next(call.args for call in run.call_args_list if call.args[0] == "sudo")
                self.assertEqual(elevation[:3] if noninteractive == "1" else elevation[:2],
                                 ("sudo", "-n", "--") if noninteractive == "1" else ("sudo", "--"))
    def provision(self, inventory=None):
        self.args.work.mkdir()
        builder.write(self.args.work / "build-inputs.json", json.dumps({
            "uid": 1000, "gid": 1000, "packages": self.packages,
        }))
        for recipe in builder.RECIPES:
            builder.write(self.args.work / "source" / recipe / "PKGBUILD", "# fixture\n")
        assembler = argparse.Namespace(
            mounted_root=lambda root: contextlib.nullcontext(),
            inventory=lambda *a: inventory if inventory is not None else {p["name"]: p["version"] for p in self.packages},
        )
        with patch.object(builder.os, "geteuid", return_value=0), \
                patch.dict(os.environ, {"SUDO_UID": "1000"}), \
                patch.object(builder.os, "chown"), \
                patch.object(builder, "load_builder", return_value=assembler), \
                patch.object(builder, "run") as run:
            builder.provision(self.args)
        return [tuple(map(str, call.args)) for call in run.call_args_list]

    def test_provisions_exact_core_versions_and_builds_unprivileged(self):
        calls = self.provision()
        config = (self.args.work / "bootstrap.conf").read_text()
        self.assertIn(f"RootDir = {self.args.work}/root\n", config)
        self.assertIn(f"Server = file://{self.args.repo}\n", config)
        self.assertEqual([line for line in config.splitlines() if line.startswith("[")],
                         ["[options]", "[devario-core]"])
        self.assertNotIn("Include", config)
        install = next(call for call in calls if "install" in call)
        self.assertEqual(install[-3:], ("gcc=1-1", "glibc=1-1", "binutils=1-1"))
        builds = [call for call in calls if "build" in call]
        self.assertEqual(len(builds), 6)
        for call in builds:
            self.assertEqual(call[0], "systemd-nspawn")
            self.assertIn("--user=devario-build", call)
            self.assertIn(f"--directory={self.args.work}/root", call)
            self.assertNotIn("--sync-deps", call)
            self.assertEqual([arg for arg in call if arg.startswith("--bind")],
                             [f"--bind={self.args.work}/artifacts:/build/artifacts"])
        isa = next(call for call in calls if any("gcc -print-file-name" in arg for arg in call))
        self.assertIn("--user=devario-build", isa)
        self.assertLess(calls.index(isa), calls.index(builds[0]))
        self.assertEqual(json.loads((self.args.work / "installed-build-inputs.json").read_text()),
                         {p["name"]: p["version"] for p in self.packages})

    def test_prepare_only_provisions_and_checks_isa_without_building(self):
        self.args.prepare_only = True
        calls = self.provision()
        self.assertTrue(any("install" in call for call in calls))
        self.assertTrue(any("gcc -print-file-name" in arg for call in calls for arg in call))
        self.assertFalse(any("build" in call for call in calls))

    def test_wrong_installed_version_stops_before_container_build(self):
        with self.assertRaisesRegex(ValueError, "differs from core: gcc"):
            self.provision({"gcc": "host-version", "glibc": "1-1", "binutils": "1-1"})
        self.assertFalse((self.args.work / "installed-build-inputs.json").exists())

    def test_unplanned_installed_package_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "differs from the core dependency plan"):
            self.provision({"gcc": "1-1", "glibc": "1-1", "binutils": "1-1", "host-extra": "1-1"})

    def artifact_metadata(self, archive, member):
        return {"pkgname": [archive.name.removesuffix(".pkg.tar.zst")], "packager": [builder.PACKAGER],
                "buildtool": ["shelly"],
                "installed": [p["name"] + "-" + p["version"] + "-x86_64" for p in self.packages]}

    def make_artifacts(self):
        for recipe in builder.RECIPES:
            (self.directory / (recipe + ".pkg.tar.zst")).touch()

    def test_complete_artifacts_record_core_toolchain(self):
        self.make_artifacts()
        with patch.object(builder, "archive_metadata", side_effect=self.artifact_metadata):
            builder.verify_artifacts(self.directory, self.packages)

    def test_host_toolchain_in_buildinfo_is_rejected(self):
        self.make_artifacts()
        def metadata(archive, member):
            result = self.artifact_metadata(archive, member)
            if member == ".BUILDINFO":
                result["installed"] = ["gcc-host-version-x86_64"]
            return result
        with patch.object(builder, "archive_metadata", side_effect=metadata):
            with self.assertRaisesRegex(ValueError, "does not record the core gcc version"):
                builder.verify_artifacts(self.directory, self.packages)

    def test_buildinfo_packager_and_missing_artifacts_are_rejected(self):
        self.make_artifacts()
        def metadata(archive, member):
            result = self.artifact_metadata(archive, member)
            if member == ".BUILDINFO":
                result["packager"] = ["Wrong packager"]
            return result
        with patch.object(builder, "archive_metadata", side_effect=metadata):
            with self.assertRaisesRegex(ValueError, "Incorrect package attribution"):
                builder.verify_artifacts(self.directory, self.packages)
        (self.directory / "calamares.pkg.tar.zst").unlink()
        with patch.object(builder, "archive_metadata", side_effect=self.artifact_metadata):
            with self.assertRaisesRegex(ValueError, "Missing installer artifacts: calamares"):
                builder.verify_artifacts(self.directory, self.packages)


if __name__ == "__main__":
    unittest.main()
