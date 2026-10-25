#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import importlib.machinery
import importlib.util
import hashlib
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
LEGACY_VERSION = "580.196.07"
PASCAL = {"address": "0000:02:00.0", "ids": ["1b80", "10de", "0000"]}
LEGACY_HTML = f'''the {LEGACY_VERSION} driver
<table><tr id="devid1340"><td>Maxwell</td></tr>
<tr id="devid1B80"><td>Pascal</td></tr>
<tr id="devid1D81"><td>Volta</td></tr>
<tr id="devid1E04"><td>Turing</td></tr>
<tr id="devid1E78_10DE_13D8"><td>Restricted</td></tr></table>
<p>Below are the legacy GPUs that are no longer supported</p>
<tr id="devid0FC0"><td>Kepler (470)</td></tr>'''
LEGACY_METADATA = {"chips": [
    {"devid": "0x1340", "features": []},
    {"devid": "0x1B80", "features": []},
    {"devid": "0x1D81", "features": []},
    {"devid": "0x1E04", "features": ["kernelopen", "gsp_proprietary_supported"]},
    {"devid": "0x1E78", "subvendorid": "0x10DE", "subdevid": "0x13D8",
     "features": ["kernelopen", "gsp_proprietary_supported"]},
    {"devid": "0x2B85", "features": ["kernelopen"]},
    {"devid": "0x0FC0", "features": [], "legacybranch": "470.xx"},
]}


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
        detector = PROJECT / "packages/devario-system-integration/gpu-driver-setup"
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

    def legacy_payload(self):
        self.payload()
        support = nvidia.proprietary_support(LEGACY_HTML, LEGACY_VERSION, LEGACY_METADATA)
        support["packages"] = {}
        for name in nvidia.LEGACY_PACKAGES:
            filename = f"{name}-{LEGACY_VERSION}-1-x86_64.pkg.tar.zst"
            archive = self.write(f"usr/share/devario/nvidia-580xx/{filename}", "archive")
            self.write(f"usr/share/devario/nvidia-580xx/{filename}.sig", "signature")
            support["packages"][name] = dict(filename=filename,
                sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                signatureSha256=hashlib.sha256(b"signature").hexdigest())
        self.write("usr/share/devario/nvidia-580xx/manifest.json", json.dumps(support))
        return support

    def installed_legacy(self):
        self.packages = {name: version for name, version in self.packages.items()
                         if name not in nvidia.OPEN_PACKAGES}
        self.packages.update({name: f"{LEGACY_VERSION}-1" for name in nvidia.LEGACY_PACKAGES})
        self.write(f"usr/src/nvidia-{LEGACY_VERSION}/dkms.conf", "source")
        self.write("usr/share/doc/nvidia/html/supportedchips.html", LEGACY_HTML)
        self.write("usr/share/doc/nvidia/supported-gpus.json", json.dumps(LEGACY_METADATA))
        for firmware in nvidia.FIRMWARE[:2]:
            self.write(f"usr/lib/firmware/nvidia/{LEGACY_VERSION}/{firmware}.zst", "firmware")

    def test_proprietary_support_excludes_older_legacy_tables(self):
        support = nvidia.proprietary_support(LEGACY_HTML, LEGACY_VERSION, LEGACY_METADATA)
        self.assertNotIn("0fc0", support["pciIds"])
        self.assertNotIn("2b85", support["pciIds"])
        self.assertIn("1e78 10de 13d8", support["pciIds"])
        for value in (LEGACY_HTML.replace(LEGACY_VERSION, "580.1.01"), ""):
            with self.assertRaises(RuntimeError):
                nvidia.proprietary_support(value, LEGACY_VERSION, LEGACY_METADATA)

    def test_selects_one_compatible_driver_for_all_gpus(self):
        self.legacy_payload()
        self.assertEqual(nvidia.select_support([DEVICE], self.root)["driverVersion"], VERSION)
        for pci_id in ("1340", "1b80", "1d81"):
            device = dict(PASCAL, ids=[pci_id, "10de", "0000"])
            self.assertEqual(nvidia.select_support([device, DEVICE], self.root)["driverVersion"], LEGACY_VERSION)
        for pci_id in ("ffff", "0fc0"):
            with self.assertRaisesRegex(RuntimeError, "neither the open driver nor"):
                nvidia.select_support([dict(PASCAL, ids=[pci_id, "10de", "0000"])], self.root)
        with self.assertRaisesRegex(RuntimeError, "neither the open driver nor"):
            nvidia.select_support([PASCAL, dict(DEVICE, ids=["2b85", "10de", "0000"])], self.root)
        modern_only = next(pci for pci in self.support["pciIds"] if pci not in ("1e04", "1e78 10de 13d8") and " " not in pci)
        with self.assertRaisesRegex(RuntimeError, "neither the open driver nor"):
            nvidia.select_support([PASCAL, dict(DEVICE, ids=[modern_only, "10de", "0000"])], self.root)

    def test_580_preflight_checks_archives_and_headers_without_installing(self):
        support = self.legacy_payload()
        with patch.object(nvidia, "output", side_effect=self.payload_output), \
                patch.object(nvidia, "install_legacy") as install:
            self.assertEqual(nvidia.check_payload([PASCAL], self.root, preflight=True), (KERNEL, LEGACY_VERSION))
            install.assert_not_called()
            entry = support["packages"]["nvidia-580xx-dkms"]
            archive = self.root / "usr/share/devario/nvidia-580xx" / entry["filename"]
            archive.write_text("corrupt")
            with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                nvidia.check_payload([PASCAL], self.root, preflight=True)

    def test_580_installed_payload_and_updates_validate_proprietary_branch(self):
        self.legacy_payload()
        self.installed_legacy()
        with patch.object(nvidia, "output", side_effect=self.payload_output):
            for updated in (False, True):
                self.assertEqual(nvidia.check_payload([PASCAL, DEVICE], self.root, updated=updated),
                                 (KERNEL, LEGACY_VERSION))
            newer = "580.200.01"
            self.packages.update({name: f"{newer}-1" for name in nvidia.LEGACY_PACKAGES})
            self.write("usr/share/doc/nvidia/html/supportedchips.html", LEGACY_HTML.replace(LEGACY_VERSION, newer))
            self.write(f"usr/src/nvidia-{newer}/dkms.conf", "source")
            for firmware in nvidia.FIRMWARE[:2]:
                self.write(f"usr/lib/firmware/nvidia/{newer}/{firmware}", "firmware")
            self.assertEqual(nvidia.check_payload([PASCAL], self.root, updated=True), (KERNEL, newer))
            self.packages["nvidia-580xx-utils"] = f"{LEGACY_VERSION}-1"
            with self.assertRaisesRegex(RuntimeError, "must be 580.200.01"):
                nvidia.check_payload([PASCAL], self.root, updated=True)

    def test_580_requires_proprietary_module_license(self):
        def info(*args):
            return {"version": LEGACY_VERSION, "vermagic": f"{KERNEL} SMP", "license": "NVIDIA"}[args[4]]
        with patch.object(nvidia, "output", side_effect=info):
            self.assertTrue(nvidia.modules_ready(KERNEL, LEGACY_VERSION))
        with patch.object(nvidia, "output", side_effect=lambda *args: "Dual MIT/GPL" if args[4] == "license" else info(*args)):
            self.assertFalse(nvidia.modules_ready(KERNEL, LEGACY_VERSION))

    def test_580_install_removes_live_packages_then_installs_signed_archives(self):
        support = self.legacy_payload()
        before = self.packages.copy()
        self.installed_legacy()
        after = self.packages.copy()
        events = []

        def run(args, **kwargs):
            conf = Path(kwargs["env"]["XDG_CONFIG_HOME"]) / "shelly/config.json"
            self.assertEqual(json.loads(conf.read_text()), {"NativePackageBackend": "rlpm"})
            events.append(args)

        with patch.object(nvidia, "legacy_archives", return_value=["/cache/dkms", "/cache/utils"]), \
                patch.object(nvidia, "installed_packages", side_effect=[before, after]), \
                patch.object(nvidia, "disable_kms", side_effect=lambda: events.append("disable")), \
                patch.object(nvidia.subprocess, "run", side_effect=run):
            nvidia.install_legacy(support)
        self.assertEqual(events[0], "disable")
        self.assertEqual(events[3], ["shelly", "remove", "standard", *nvidia.OPEN_PACKAGES, "--no-cascade", "--no-confirm"])
        self.assertEqual(events[4], ["shelly", "install", "standard", "/cache/dkms", "/cache/utils", "--no-confirm"])
        self.assertEqual(events[-1][0], "gpgconf")
        with patch.object(nvidia, "legacy_archives", return_value=[]), \
                patch.object(nvidia, "installed_packages", return_value=after), \
                patch.object(nvidia.subprocess, "run") as transaction:
            nvidia.install_legacy(support)
            transaction.assert_not_called()

    def test_580_failed_install_cannot_enable_kms(self):
        self.legacy_payload()
        with patch.object(nvidia, "select_support", return_value={"driverVersion": LEGACY_VERSION, "pciIds": ["1b80"]}), \
                patch.object(nvidia, "install_legacy", side_effect=subprocess.CalledProcessError(1, "shelly")), \
                patch.object(nvidia, "enable_kms") as enable:
            with self.assertRaises(subprocess.CalledProcessError):
                nvidia.configure([PASCAL])
            enable.assert_not_called()

    def test_580_transaction_failure_stops_and_cleans_up_keyring(self):
        support = self.legacy_payload()
        events = []

        def run(args, **kwargs):
            events.append(args)
            if args[:2] == ["shelly", "remove"]:
                raise subprocess.CalledProcessError(1, args)

        with patch.object(nvidia, "legacy_archives", return_value=["/cache/dkms", "/cache/utils"]), \
                patch.object(nvidia, "installed_packages", return_value=self.packages), \
                patch.object(nvidia, "disable_kms"), \
                patch.object(nvidia.subprocess, "run", side_effect=run):
            with self.assertRaises(subprocess.CalledProcessError):
                nvidia.install_legacy(support)
        self.assertFalse(any(args[:2] == ["shelly", "install"] for args in events))
        self.assertEqual(events[-1][0], "gpgconf")

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

    def test_updated_driver_uses_signed_dkms_source_support_table(self):
        self.payload()
        version = "616.10.01"
        self.packages.update({"nvidia-open-dkms": f"{version}-1", "nvidia-utils": f"{version}-2"})
        readme = f"NVIDIA open kernel modules, version {version}.\n## Compatible GPUs\n" \
                 "| GPU | PCI ID |\n| Example | 1E04 |\n| Restricted | 1E78 10DE 13D8 |\n\n## Other\n"
        self.write(f"usr/src/nvidia-{version}/README.md", readme)
        self.write(f"usr/src/nvidia-{version}/dkms.conf", "source")
        for firmware in nvidia.FIRMWARE:
            self.write(f"usr/lib/firmware/nvidia/{version}/{firmware}.zst", "firmware")
        with patch.object(nvidia, "output", side_effect=self.payload_output):
            self.assertEqual(nvidia.check_payload([DEVICE], self.root, updated=True), (KERNEL, version))
            with self.assertRaisesRegex(RuntimeError, "must be 615"):
                nvidia.check_payload([DEVICE], self.root)
            self.packages["nvidia-utils"] = f"{VERSION}-1"
            with self.assertRaisesRegex(RuntimeError, "must be 616"):
                nvidia.check_payload([DEVICE], self.root, updated=True)
            self.packages["nvidia-utils"] = f"{version}-1"
            for bad in (readme.replace(version, VERSION), readme.replace("1E04", "FFFF"),
                        readme.replace("## Compatible GPUs", "## Missing table")):
                self.write(f"usr/src/nvidia-{version}/README.md", bad)
                with self.assertRaises(RuntimeError):
                    nvidia.check_payload([DEVICE], self.root, updated=True)

    def test_updated_configuration_dispatch(self):
        with patch.object(nvidia.sys, "argv", [str(HELPER), "--configure-updated"]), \
                patch.object(nvidia, "detect", return_value=[DEVICE]), \
                patch.object(nvidia, "configure") as configure:
            nvidia.main()
            configure.assert_called_once_with([DEVICE], updated=True)

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

    def test_preflight_dispatch_handles_gpu_and_no_gpu(self):
        with patch.object(nvidia.sys, "argv", [str(HELPER), "--preflight"]), \
                patch.object(nvidia, "detect", return_value=[DEVICE]), \
                patch.object(nvidia, "preflight") as preflight:
            nvidia.main()
            preflight.assert_called_once_with([DEVICE])
        for mode in ("--configure", "--preflight"):
            with patch.object(nvidia.sys, "argv", [str(HELPER), mode]), \
                    patch.object(nvidia, "detect", return_value=[]), \
                    patch.object(nvidia, "configure") as configure, \
                    patch.object(nvidia, "preflight") as preflight:
                nvidia.main()
                if mode == '--configure':
                    configure.assert_called_once_with([])
                    preflight.assert_not_called()
                else:
                    preflight.assert_called_once_with([])
                    configure.assert_not_called()

    def test_no_gpu_skips_preflight_and_never_calls_shelly(self):
        with patch.object(nvidia.subprocess, "run") as run:
            nvidia.preflight([])
            run.assert_not_called()

    def test_no_gpu_does_not_validate_payload_or_build_modules(self):
        with patch.object(nvidia, "check_payload") as check, \
                patch.object(nvidia, "disable_kms") as disable, \
                patch.object(nvidia, "remove_unused_nvidia") as remove, \
                patch.object(nvidia.subprocess, "run") as run:
            nvidia.configure([])
            disable.assert_called_once_with()
            remove.assert_called_once_with()
            check.assert_not_called()
            run.assert_not_called()

    def test_no_gpu_removes_only_installed_nvidia_packages_with_rlpm(self):
        before = {"nvidia-open-dkms": f"{VERSION}-1", "nvidia-utils": f"{VERSION}-1",
                  "dkms": "3.1-1", "linux-devario-headers": "7.2.7-1"}
        after = {"dkms": "3.1-1", "linux-devario-headers": "7.2.7-1"}
        inventory = [before, after]
        def assert_backend(args, **kwargs):
            directory = Path(kwargs["env"]["XDG_CONFIG_HOME"])
            self.assertEqual(json.loads((directory / "shelly/config.json").read_text()), {
                "NativePackageBackend": "rlpm",
            })
        with patch.object(nvidia, "installed_packages", side_effect=inventory), \
                patch.object(nvidia.subprocess, "run", side_effect=assert_backend) as run:
            nvidia.remove_unused_nvidia()
            run.assert_called_once()
            args = run.call_args.args[0]
            self.assertEqual(args, ["shelly", "remove", "standard", "nvidia-open-dkms",
                                    "nvidia-utils", "--no-cascade", "--no-confirm"])
            self.assertTrue(run.call_args.kwargs["check"])
            self.assertIn("XDG_CONFIG_HOME", run.call_args.kwargs["env"])
            self.assertIn("devario-nvidia-rlpm-", run.call_args.kwargs["env"]["XDG_CONFIG_HOME"])

    def test_no_gpu_removal_errors_instead_of_ignoring_stale_metapackage(self):
        installed = {"nvidia-open-dkms": f"{VERSION}-1"}
        with patch.object(nvidia, "installed_packages", return_value=installed), \
                patch.object(nvidia.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "shelly")):
            with self.assertRaisesRegex(RuntimeError, "rebuild the metapackage"):
                nvidia.remove_unused_nvidia()
        with patch.object(nvidia, "installed_packages", side_effect=[installed, installed]), \
                patch.object(nvidia.subprocess, "run"):
            with self.assertRaisesRegex(RuntimeError, "packages remain"):
                nvidia.remove_unused_nvidia()
        with patch.object(nvidia, "installed_packages", return_value={}), \
                patch.object(nvidia.subprocess, "run") as run:
            nvidia.remove_unused_nvidia()
            run.assert_not_called()

    def test_no_gpu_removes_580_packages_too(self):
        before = {name: f"{LEGACY_VERSION}-1" for name in nvidia.LEGACY_PACKAGES}
        with patch.object(nvidia, "installed_packages", side_effect=[before, {}]), \
                patch.object(nvidia.subprocess, "run") as run:
            nvidia.remove_unused_nvidia()
        self.assertEqual(run.call_args.args[0], ["shelly", "remove", "standard", *nvidia.LEGACY_PACKAGES,
                                                "--no-cascade", "--no-confirm"])

    def test_disable_kms_preserves_unrelated_settings(self):
        config = self.write("etc/devario-dracut.conf",
                            'BUILD_UKI="false"\nNVIDIA_EARLY_KMS="true"\n')
        modprobe = self.write("etc/modprobe.d/devario-nvidia.conf",
                              "# Managed by the Devario installer.\noptions nvidia_drm modeset=1\n")
        nvidia.disable_kms(config, modprobe)
        self.assertEqual(config.read_text(), 'BUILD_UKI="false"\nNVIDIA_EARLY_KMS="false"\n')
        self.assertFalse(modprobe.exists())
        nvidia.disable_kms(config, modprobe)
        self.assertEqual(config.read_text().count('NVIDIA_EARLY_KMS="false"'), 1)
        modprobe.write_text("# user managed\n")
        with self.assertRaisesRegex(RuntimeError, "non-installer-owned"):
            nvidia.disable_kms(config, modprobe)
        self.assertEqual(modprobe.read_text(), "# user managed\n")

    def test_calamares_order_and_package_contract(self):
        import yaml
        settings = yaml.safe_load((PROFILE / "airootfs/etc/calamares/settings.conf").read_text())
        sequence = next(step["exec"] for step in settings["sequence"] if "exec" in step)
        self.assertLess(sequence.index("shellprocess@nvidia_preflight"), sequence.index("partition"))
        self.assertLess(sequence.index("unpackfs"), sequence.index("shellprocess@nvidia"))
        self.assertLess(sequence.index("networkcfg"), sequence.index("shellprocess@nvidia"))
        self.assertLess(sequence.index("shellprocess@nvidia"), sequence.index("shellprocess@systemd_boot"))
        for name, chroot, timeout in (("nvidia_preflight", True, 120), ("nvidia", False, 1800)):
            instance = next(i for i in settings["instances"] if i["id"] == name)
            self.assertEqual(instance["module"], "shellprocess")
            config = yaml.safe_load((PROFILE / "airootfs/etc/calamares/modules" / instance["config"]).read_text())
            self.assertEqual(config["dontChroot"], chroot)
            self.assertGreaterEqual(config["timeout"], timeout)
            self.assertFalse(config["verbose"], "Calamares must retain output for its error dialog")
            self.assertEqual(config["script"], [nvidia.HELPER + (" --preflight" if chroot else " --configure")])
        permissions = json.loads((PROFILE / "profile.json").read_text())["permissions"]
        self.assertEqual(permissions[nvidia.HELPER], "755")
        packages = set((PROFILE / "packages.x86_64").read_text().splitlines())
        self.assertTrue({"devario-desktop", "nvidia-open-dkms", "nvidia-utils"} <= packages)

    def test_local_package_checksums(self):
        import hashlib
        # Kernel/dracut recipes are validated by their external package build.
        for name in ("devario-boot",):
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
