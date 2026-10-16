#!/usr/bin/env python3
import configparser
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import yaml

PROJECT = Path(__file__).resolve().parents[1]


def module(path, name):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


audit = module(PROJECT / "scripts/audit-iso-repositories.py", "audit")


class IndependenceTests(unittest.TestCase):
    def test_repository_defaults(self):
        repositories = json.loads((PROJECT / "repositories/defaults.json").read_text())["repositories"]
        names = ["devario-core", "devario-browser", "devario-development",
                 "devario-entertainment", "devario-gaming", "devario-utilities",
                 "devario-productivity", "devario-libs"]
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

    def test_plymouth_live_and_installed_defaults(self):
        packages = set((PROJECT / "iso/packages.x86_64").read_text().splitlines())
        self.assertTrue({"plymouth", "devario-plymouth-theme"} <= packages)
        config = configparser.ConfigParser()
        config.read(PROJECT / "iso/late-airootfs/etc/plymouth/plymouthd.conf")
        self.assertEqual(config["Daemon"]["Theme"], "devario")
        # Cover BIOS, UEFI, loopback and network boot command lines.
        paths = [*(PROJECT / "iso/syslinux").glob("*.cfg"),
                 *(PROJECT / "iso/grub").glob("*.cfg"),
                 *(PROJECT / "iso/efiboot/loader/entries").glob("*.conf")]
        commands = [line.split() for path in paths for line in path.read_text().splitlines()
                    if line.lstrip().startswith(("APPEND ", "linux ", "options "))
                    and "root=live:" in line]
        self.assertGreaterEqual(len(commands), 7)
        for command in commands:
            self.assertIn("quiet", command)
            self.assertIn("splash", command)
        # Both profiles bypass /etc/dracut.conf.d, so must request Plymouth directly.
        for mode in ("live", "installed"):
            profile = (PROJECT / f"packages/devario-boot/{mode}.conf").read_text()
            modules = next(line for line in profile.splitlines() if line.startswith("add_dracutmodules"))
            self.assertIn("plymouth", modules.split())

    def test_ufw_live_and_installed_defaults(self):
        for name in ("iso/packages.x86_64", "repository-packages.x86_64"):
            self.assertIn("ufw", (PROJECT / name).read_text().splitlines())
        services = yaml.safe_load((PROJECT / "iso/airootfs/etc/calamares/modules/services-systemd.conf").read_text())
        self.assertIn(dict(name="ufw.service", action="enable", mandatory=True), services["units"])
        source_link = PROJECT / "iso/late-airootfs/etc/systemd/system/multi-user.target.wants/ufw.service"
        self.assertFalse(source_link.is_symlink(), "package-provided targets must not be linked in the source archive")
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / "profile"
            shutil.copytree(PROJECT / "iso/late-airootfs", profile / "late-airootfs", symlinks=True)
            subprocess.run(["bash", str(PROJECT / "scripts/stage-image-links.sh"), str(profile)], check=True)
            self.assertEqual((profile / "airootfs/etc/calamares/qml").readlink(), Path("/usr/share/calamares/qml"))
            self.assertEqual((profile / "airootfs/etc/localtime").readlink(), Path("../usr/share/zoneinfo/UTC"))
            root = Path(directory) / "live"
            # Model package defaults followed by the late image overlay.
            (root / "etc/ufw").mkdir(parents=True)
            (root / "etc/ufw/ufw.conf").write_text("ENABLED=no\n")
            unit = root / "usr/lib/systemd/system/ufw.service"
            unit.parent.mkdir(parents=True)
            unit.write_text("[Unit]\nDescription=UFW fixture\n[Service]\nType=oneshot\nExecStart=/usr/lib/ufw/ufw-init start\n[Install]\nWantedBy=multi-user.target\n")
            shutil.copytree(profile / "late-airootfs", root, symlinks=True, dirs_exist_ok=True)
            # Calamares unpacks the pristine image into the installation target.
            installed = Path(directory) / "installed"
            shutil.copytree(root, installed, symlinks=True)
            for target in (root, installed):
                with self.subTest(target=target.name):
                    state = subprocess.check_output([
                        "systemctl", "--root", str(target), "is-enabled", "ufw.service"
                    ], text=True).strip()
                    self.assertEqual(state, "enabled")
                    values = subprocess.check_output([
                        "bash", "-c", 'source "$1"; source "$2"; printf "%s\\n" "$ENABLED" "$LOGLEVEL" "$IPV6" "$DEFAULT_INPUT_POLICY" "$DEFAULT_OUTPUT_POLICY" "$DEFAULT_FORWARD_POLICY" "$DEFAULT_APPLICATION_POLICY"',
                        "test", str(target / "etc/ufw/ufw.conf"), str(target / "etc/default/ufw")
                    ], text=True).splitlines()
                    self.assertEqual(values, ["yes", "low", "yes", "DROP", "ACCEPT", "DROP", "SKIP"])

    def test_name_coverage_defers_version_constraints_to_shelly(self):
        # This source-only preflight inventories names; Shelly decides whether
        # the selected snapshot can satisfy the original version constraints.
        packages = [dict(name="app", version="1", provides=[],
                         depends=["engine>=2", "missing>=3"]),
                    dict(name="engine-provider", version="1", provides=["engine=1"], depends=[])]
        selected, missing = audit.resolve(["app>=2"], packages)
        self.assertEqual(set(selected), {"app", "engine-provider"})
        self.assertEqual(selected["app"]["depends"], ["engine>=2", "missing>=3"])
        self.assertEqual(missing, {"missing>=3": ["app"]})


if __name__ == "__main__":
    unittest.main()
