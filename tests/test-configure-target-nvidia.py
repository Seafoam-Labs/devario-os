#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]
PROFILE = Path(os.environ.get("DEVARIO_PROFILE_DIR", PROJECT / "iso"))
HELPER = PROFILE / "airootfs/usr/lib/devario/configure-target-nvidia"
loader = importlib.machinery.SourceFileLoader("nvidia", str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
nvidia = importlib.util.module_from_spec(spec)
# Import without writing bytecode into the ISO filesystem overlay.
exec(compile(HELPER.read_text(), str(HELPER), "exec"), nvidia.__dict__)
SUPPORT = PROFILE / "airootfs/usr/share/devario/nvidia-supported-gpus.json"
VERSION = "615.71.09"
KERNEL = "7.2.7-1-devario"
DEVICE = {"address": "0000:01:00.0", "ids": ["1e04", "10de", "0000"]}


class NvidiaTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="devario-nvidia-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.support = json.loads(SUPPORT.read_text())
        logger = patch.object(nvidia, "log")
        logger.start()
        self.addCleanup(logger.stop)

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def test_support_table_and_subsystems(self):
        self.assertEqual(self.support["driverVersion"], VERSION)
        nvidia.check_support([DEVICE], self.support)
        restricted = {"address": "0000:02:00.0", "ids": ["1e78", "10de", "13d8"]}
        nvidia.check_support([restricted], self.support)
        for ids in (["1e78", "ffff", "ffff"], ["1b80", "10de", "0000"], ["ffff", "0000", "0000"]):
            with self.subTest(ids=ids), self.assertRaises(RuntimeError):
                nvidia.check_support([DEVICE, {"address": "0000:02:00.0", "ids": ids}], self.support)

    def test_detection_reuses_real_detector(self):
        detector = PROJECT / "packages/devario-aqueous-desktop/gpu-driver-setup"
        real_run = subprocess.run

        def run(args, **kwargs):
            return real_run(["bash", str(detector), *args[1:]], **kwargs)

        with patch.object(nvidia.subprocess, "run", side_effect=run), \
                patch.dict(os.environ, {"DEVARIO_PCI_DEVICES_ROOT": str(self.root)}):
            self.assertEqual(nvidia.detect(), [])
            for addr, vendor, klass in (("0000:00:02.0", "8086", "030000"),
                                        ("0000:03:00.0", "1002", "030000"),
                                        ("0000:01:00.1", "10de", "040300")):
                self.write(f"{addr}/vendor", f"0x{vendor}\n")
                self.write(f"{addr}/class", f"0x{klass}\n")
            self.assertEqual(nvidia.detect(), [])
            for field, value in zip(("device", "subsystem_vendor", "subsystem_device"), DEVICE["ids"]):
                self.write(f"{DEVICE['address']}/{field}", f"0x{value}\n")
            self.write(f"{DEVICE['address']}/vendor", "0x10DE\n")
            self.write(f"{DEVICE['address']}/class", "0x030200\n")
            self.assertEqual(nvidia.detect(), [DEVICE])
            (self.root / DEVICE["address"] / "class").unlink()
            with self.assertRaises(RuntimeError):
                nvidia.detect()
        with patch.object(nvidia.subprocess, "run", side_effect=run), \
                patch.dict(os.environ, {"DEVARIO_PCI_DEVICES_ROOT": str(self.root / "missing")}):
            with self.assertRaises(RuntimeError):
                nvidia.detect()

    def test_configuration_preserves_settings_and_is_idempotent(self):
        config = self.write("etc/devario-dracut.conf", '# keep\nDRACUT_QUIET="true"\n'
                            '#NVIDIA_EARLY_KMS="false"\nNVIDIA_EARLY_KMS="false"\n'
                            ' export NVIDIA_EARLY_KMS="false"\nBUILD_UKI="false"')
        config.chmod(0o640)
        modprobe = self.root / "etc/modprobe.d/devario-nvidia.conf"
        nvidia.enable_kms(config, modprobe)
        first = config.read_text()
        self.assertIn('DRACUT_QUIET="true"', first)
        self.assertIn('BUILD_UKI="false"\n', first)
        self.assertIn('#NVIDIA_EARLY_KMS="false"', first)
        self.assertEqual(first.count('NVIDIA_EARLY_KMS="true"'), 1)
        nvidia.enable_kms(config, modprobe)
        self.assertEqual(config.read_text(), first)
        self.assertEqual(config.stat().st_mode & 0o777, 0o640)
        self.assertIn("options nvidia_drm modeset=1", modprobe.read_text())
        config.unlink()
        nvidia.enable_kms(config, modprobe)
        self.assertEqual(config.read_text(), 'NVIDIA_EARLY_KMS="true"\n')

    def payload(self):
        self.write("usr/share/devario/nvidia-supported-gpus.json", SUPPORT.read_text())
        self.write(f"usr/lib/modules/{KERNEL}/build/Makefile", "headers")
        self.write(f"usr/lib/modules/{KERNEL}/build/include/config/kernel.release", KERNEL)
        self.write(f"usr/src/nvidia-{VERSION}/dkms.conf", "source")
        for firmware in nvidia.FIRMWARE:
            self.write(f"usr/lib/firmware/nvidia/{VERSION}/{firmware}.zst", "firmware")
        self.packages = {name: "1-1" for name in ("dkms", "gcc", "make", "patch")}
        self.packages.update({"linux-devario": "7.2.7-1", "linux-devario-headers": "7.2.7-1",
                              "nvidia-utils": f"{VERSION}-2", "nvidia-open-dkms": f"{VERSION}-1"})

    def payload_output(self, *args):
        if args[0] == "shelly":
            return json.dumps([{"Name": k, "Version": v} for k, v in self.packages.items()])
        self.assertEqual(args[0], "bash")
        self.assertNotIn("uname", " ".join(args))
        return KERNEL

    def test_payload_versions_headers_sources_firmware(self):
        self.payload()
        with patch.object(nvidia, "output", side_effect=self.payload_output):
            self.assertEqual(nvidia.check_payload([DEVICE], self.root), (KERNEL, VERSION))
            self.packages["nvidia-utils"] = "580.95.05-1"
            with self.assertRaisesRegex(RuntimeError, "must be 615"):
                nvidia.check_payload([DEVICE], self.root)
            self.packages["nvidia-utils"] = f"{VERSION}-1"
            self.packages["linux-devario-headers"] = "7.2.7-2"
            with self.assertRaisesRegex(RuntimeError, "versions differ"):
                nvidia.check_payload([DEVICE], self.root)
            self.packages["linux-devario-headers"] = "7.2.7-1"
            del self.packages["dkms"]
            with self.assertRaisesRegex(RuntimeError, "missing dkms"):
                nvidia.check_payload([DEVICE], self.root)
            self.packages["dkms"] = "1-1"
            for relative in (f"usr/lib/modules/{KERNEL}/build/Makefile",
                             f"usr/src/nvidia-{VERSION}/dkms.conf",
                             f"usr/lib/firmware/nvidia/{VERSION}/ucodes_ga10x.bin.zst"):
                path = self.root / relative
                saved = path.read_bytes()
                path.unlink()
                with self.subTest(missing=relative), self.assertRaises(RuntimeError):
                    nvidia.check_payload([DEVICE], self.root)
                path.write_bytes(saved)

    def test_module_checks(self):
        def info(*args):
            self.assertEqual(args[:3], ("modinfo", "-k", KERNEL))
            return {"version": VERSION, "vermagic": f"{KERNEL} SMP", "license": "Dual MIT/GPL"}[args[4]]
        with patch.object(nvidia, "output", side_effect=info):
            self.assertTrue(nvidia.modules_ready(KERNEL, VERSION))
        with patch.object(nvidia, "output", return_value="580.95.05"):
            self.assertFalse(nvidia.modules_ready(KERNEL, VERSION))
        with patch.object(nvidia, "output", side_effect=subprocess.CalledProcessError(1, "modinfo")):
            self.assertFalse(nvidia.modules_ready(KERNEL, VERSION))

    def test_dkms_order_and_failure_do_not_enable_kms(self):
        for states, failure in (([True, True], False), ([False, True], False),
                                ([False], True), ([False, False], False)):
            events = []

            def run(args, **kwargs):
                events.append(args)
                if failure:
                    raise subprocess.CalledProcessError(1, args)

            with self.subTest(states=states, failure=failure), \
                    patch.object(nvidia, "check_payload", return_value=(KERNEL, VERSION)), \
                    patch.object(nvidia, "modules_ready", side_effect=states), \
                    patch.object(nvidia.subprocess, "run", side_effect=run), \
                    patch.object(nvidia, "enable_kms", side_effect=lambda: events.append("enabled")):
                if failure or not states[-1]:
                    with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                        nvidia.configure([DEVICE])
                    self.assertNotIn("enabled", events)
                else:
                    nvidia.configure([DEVICE])
                    self.assertEqual(events[-2:], [["depmod", "-a", KERNEL], "enabled"])
                if not states[0]:
                    self.assertEqual(events[0], ["dkms", "autoinstall", "-k", KERNEL])
                self.assertFalse(any("modprobe" in e for e in events))

    def test_preflight_checks_pristine_root_and_no_gpu_skips(self):
        with patch.object(nvidia.sys, "argv", [str(HELPER), "--preflight"]), \
                patch.object(nvidia, "detect", return_value=[DEVICE]), \
                patch.object(nvidia.subprocess, "run") as run:
            nvidia.main()
            args, kwargs = run.call_args
            self.assertEqual(args[0], ["chroot", "/run/devario/install-root", nvidia.HELPER, "--check-payload"])
            self.assertEqual(json.loads(kwargs["input"]), [DEVICE])
        for mode in ("--configure", "--preflight"):
            with patch.object(nvidia.sys, "argv", [str(HELPER), mode]), \
                    patch.object(nvidia, "detect", return_value=[]), \
                    patch.object(nvidia, "configure") as configure, \
                    patch.object(nvidia.subprocess, "run") as run:
                nvidia.main()
                configure.assert_not_called()
                run.assert_not_called()

    def test_calamares_order_and_package_contract(self):
        import yaml
        settings = yaml.safe_load((PROFILE / "airootfs/etc/calamares/settings.conf").read_text())
        sequence = next(step["exec"] for step in settings["sequence"] if "exec" in step)
        self.assertLess(sequence.index("shellprocess@nvidia_preflight"), sequence.index("partition"))
        self.assertLess(sequence.index("unpackfs"), sequence.index("shellprocess@nvidia"))
        self.assertLess(sequence.index("networkcfg"), sequence.index("shellprocess@nvidia"))
        self.assertLess(sequence.index("shellprocess@nvidia"), sequence.index("shellprocess@limine"))
        for name, chroot, timeout in (("nvidia_preflight", True, 120), ("nvidia", False, 1800)):
            instance = next(i for i in settings["instances"] if i["id"] == name)
            self.assertEqual(instance["module"], "shellprocess")
            config = yaml.safe_load((PROFILE / "airootfs/etc/calamares/modules" / instance["config"]).read_text())
            self.assertEqual(config["dontChroot"], chroot)
            self.assertGreaterEqual(config["timeout"], timeout)
            self.assertEqual(config["script"], [nvidia.HELPER + (" --preflight" if chroot else " --configure")])
        permissions = json.loads((PROFILE / "profile.json").read_text())["permissions"]
        self.assertEqual(permissions[nvidia.HELPER], "755")
        recipe = (PROJECT / "packages/devario-aqueous-desktop/PKGBUILD").read_text()
        for name in ("nvidia-open-dkms", "nvidia-utils"):
            self.assertIn(f"'{name}={VERSION}'", recipe)

    def test_local_package_checksums(self):
        import hashlib
        # Kernel/dracut recipes are validated by their external package build.
        for name in ("devario-boot", "devario-aqueous-desktop"):
            folder = PROJECT / "packages" / name
            # Read recipe metadata; this does not execute its build functions.
            metadata = subprocess.check_output([
                "bash", "-c", 'source "$1"; for i in "${!source[@]}"; do '
                'printf "%s\\t%s\\t%s\\n" "${source[$i]}" "${sha256sums[$i]:-}" "${sha512sums[$i]:-}"; done',
                "bash", str(folder / "PKGBUILD")], text=True)
            for row in metadata.splitlines():
                filename, sha256, sha512 = row.split("\t")
                if "://" in filename:
                    continue
                algorithm, expected = ("sha256", sha256) if sha256 else ("sha512", sha512)
                with self.subTest(package=name, source=filename):
                    self.assertEqual(hashlib.new(algorithm, (folder / filename).read_bytes()).hexdigest(), expected)


if __name__ == "__main__":
    unittest.main()
