#!/usr/bin/env python3
import configparser
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]


def module(path, name):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


compat = module(PROJECT / "packages/shelly-arch-compat/shelly-arch-compat", "compat")
audit = module(PROJECT / "scripts/audit-iso-repositories.py", "audit")


class IndependenceTests(unittest.TestCase):
    def test_repository_defaults(self):
        repositories = json.loads((PROJECT / "repositories/defaults.json").read_text())["repositories"]
        names = ["devario-core", "devario-browser", "devario-development",
                 "devario-entertainment", "devario-gaming", "devario-utilities",
                 "devario-productivity", "devario-scx"]
        self.assertEqual([r["name"] for r in repositories], names)
        for path in ("packages/devario-base/shelly.conf", "iso/shelly.runtime.conf"):
            with self.subTest(path=path):
                runtime = (PROJECT / path).read_text()
                core_url = repositories[0]["server"]
                if path.startswith("iso/"):
                    core_url = "https://snapshot.example.test/devario-core/x86_64"
                    runtime = runtime.replace("@DEVARIO_CORE_RUNTIME_REPO@", core_url)
                    runtime = runtime.replace("@DEVARIO_CORE_RUNTIME_SIGLEVEL@", "Required")
                    runtime = runtime.replace("@DEVARIO_MANAGED_RUNTIME_REPOSITORY@", "")
                # Shelly permits repeated options such as HookDir.
                config = configparser.ConfigParser(interpolation=None, allow_no_value=True, strict=False)
                config.read_string(runtime)
                self.assertEqual(config.sections(), ["options", *names])
                for repo in repositories:
                    section = config[repo["name"]]
                    self.assertEqual(section["SigLevel"], "Required")
                    self.assertEqual(section["Server"], core_url if repo["name"] == "devario-core" else repo["server"])

    def test_compatibility_preserves_configuration(self):
        original = "[options]\n# user configuration\n[devario-core]\nServer = https://example.test/\n"
        enabled = compat.change(original, True)
        self.assertTrue(enabled.startswith(original))
        self.assertEqual(compat.change(enabled, True), enabled)
        self.assertEqual(compat.change(enabled, False).rstrip(), original.rstrip())
        self.assertTrue(compat.protected("devario-filesystem"))
        self.assertTrue(compat.protected("linux-devario"))
        self.assertTrue(compat.protected("linux-devario-headers"))
        self.assertFalse(compat.protected("example-application"))
        with self.assertRaises(ValueError):
            compat.change(original + "[core]\nServer = https://user.test/\n", True)
        with self.assertRaises(ValueError):
            compat.change(original + compat.START, False)

    def test_dependency_audit(self):
        packages = [dict(name="devario-filesystem", version="1", repository="devario-core",
                         depends=[], provides=["filesystem=2026.09"], filename="fs.pkg.tar.zst"),
                    dict(name="app", version="1", repository="seafoam-labs", depends=["filesystem>=2026", "absent"],
                         provides=[], filename="app.pkg.tar.zst")]
        selected, missing = audit.resolve(["app"], packages)
        self.assertEqual(set(selected), {"app", "devario-filesystem"})
        self.assertEqual(missing, {"absent": ["app"]})

    def test_identity_and_boot_names(self):
        self.assertNotIn("ID_LIKE=arch", (PROJECT / "iso/airootfs/etc/os-release").read_text())
        configs = list((PROJECT / "iso/syslinux").glob("*.cfg"))
        self.assertTrue(configs)
        for path in configs:
            self.assertNotIn("archiso", path.name)
            self.assertNotIn("archiso_", path.read_text())
        self.assertFalse((PROJECT / "iso/profiledef.sh").exists())
        self.assertEqual(json.loads((PROJECT / "iso/profile.json").read_text())["schemaVersion"], 1)

    def test_version_comparison_without_vercmp(self):
        # Ubuntu CI installs the ALPM library without makepkg/vercmp. Exercise
        # real ALPM semantics, including epoch, package release and prerelease.
        with patch.object(audit.shutil, "which", return_value=None):
            for left, right, sign in (
                ("1:1.0-1", "9.0-9", 1),
                ("1.0-2", "1.0-1", 1),
                ("1.0rc1", "1.0", -1),
                ("1.0-1", "1.0-1", 0),
            ):
                with self.subTest(left=left, right=right):
                    result = audit.compare_versions(left, right)
                    self.assertEqual((result > 0) - (result < 0), sign)


if __name__ == "__main__":
    unittest.main()
