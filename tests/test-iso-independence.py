#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import unittest

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
        self.assertEqual([r["name"] for r in repositories], ["devario-core", "seafoam-labs"])
        runtime = (PROJECT / "packages/devario-alpm-runtime/shelly.conf").read_text()
        for repo in repositories:
            self.assertIn("[" + repo["name"] + "]", runtime)
            self.assertIn(repo["server"], runtime)
        self.assertLess(runtime.index("[devario-core]"), runtime.index("[seafoam-labs]"))
        self.assertNotIn("[core]", runtime)
        self.assertNotIn("[extra]", runtime)

    def test_compatibility_preserves_configuration(self):
        original = "[options]\n# user configuration\n[devario-core]\nServer = https://example.test/\n"
        enabled = compat.change(original, True)
        self.assertTrue(enabled.startswith(original))
        self.assertEqual(compat.change(enabled, True), enabled)
        self.assertEqual(compat.change(enabled, False).rstrip(), original.rstrip())
        self.assertTrue(compat.protected("devario-filesystem"))
        self.assertTrue(compat.protected("linux-cachyos-lts"))
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


if __name__ == "__main__":
    unittest.main()
