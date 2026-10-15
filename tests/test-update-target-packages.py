#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error

PROJECT = Path(__file__).resolve().parents[1]
PROFILE = Path(os.environ.get("DEVARIO_PROFILE_DIR", PROJECT / "iso"))
HELPER = PROFILE / "airootfs/usr/lib/devario/update-target-packages"
update = ModuleType("update_target")
exec(compile(HELPER.read_text(), str(HELPER), "exec"), update.__dict__)


class UpdateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="devario-update-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.enterContext(patch.object(update, "log"))
        self.enterContext(patch.object(update.time, "sleep"))

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def test_repository_includes_and_edition_servers(self):
        self.write("etc/shelly.conf", "[options]\nArchitecture = testarch\n"
                   "[devario-core]\nInclude = /etc/shelly.d/mirrors\n"
                   "[devario-managed]\nServer = https://managed.test/$repo/$arch\n")
        self.write("etc/shelly.d/mirrors", "Server = https://one.test/$repo/$arch\n"
                   "Server = https://two.test/$arch\n")
        self.assertEqual(update.repository_servers(self.root), {
            "devario-core": ["https://one.test/devario-core/testarch", "https://two.test/testarch"],
            "devario-managed": ["https://managed.test/devario-managed/testarch"]})
        self.write("etc/shelly.d/mirrors", "Include = /etc/shelly.conf\n")
        with self.assertRaisesRegex(RuntimeError, "Recursive"):
            update.repository_servers(self.root)
        self.write("etc/shelly.d/mirrors", "Include = /missing\n")
        with self.assertRaisesRegex(RuntimeError, "missing"):
            update.repository_servers(self.root)

    def test_connectivity_retries_and_falls_back_without_package_mutation(self):
        self.write("etc/shelly.conf", "[core]\nServer = https://bad.test/$arch\n"
                   "Server = https://good.test/$arch\n")
        requests = []

        def fetch(request, **kwargs):
            requests.append(request.full_url)
            if "bad.test" in request.full_url:
                raise urllib.error.URLError("DNS unavailable")
            from contextlib import nullcontext
            return nullcontext(SimpleNamespace(url=request.full_url, read=lambda n: b"x"))

        with patch.object(update.urllib.request, "urlopen", side_effect=fetch), \
                patch.object(update.subprocess, "run") as run:
            update.check_connectivity(self.root)
            self.assertEqual(len(requests), 4)
            run.assert_not_called()

    def test_unreachable_repository_and_clock_fail_before_installation(self):
        self.write("etc/shelly.conf", "[core]\nServer = https://bad.test\n")
        with patch.object(update.urllib.request, "urlopen", side_effect=urllib.error.URLError("TLS failed")) as fetch:
            with self.assertRaisesRegex(RuntimeError, "Cannot reach repository core"):
                update.check_connectivity(self.root)
            self.assertEqual(fetch.call_count, 3)
        with patch.object(update.time, "time", return_value=0), \
                self.assertRaisesRegex(RuntimeError, "clock predates"):
            update.check_connectivity(self.root)

    def test_http_and_empty_repository_fail(self):
        for config in ("[core]\nServer = http://insecure.test\n", "[core]\n"):
            self.write("etc/shelly.conf", config)
            with self.assertRaises(RuntimeError):
                update.check_connectivity(self.root)

    def test_resolver_restores_files_symlinks_and_absence_on_failure(self):
        source = self.write("live-resolver", "nameserver 192.0.2.1\n")
        target = self.root / "etc/resolv.conf"
        target.parent.mkdir()
        for kind in ("file", "symlink", "absent"):
            with self.subTest(kind=kind):
                if kind == "file":
                    target.write_text("original\n")
                    target.chmod(0o640)
                elif kind == "symlink":
                    target.symlink_to("/run/nonexistent/resolv.conf")
                with self.assertRaisesRegex(RuntimeError, "simulated transaction failure"):
                    with update.target_resolver(self.root, source):
                        self.assertFalse(target.is_symlink())
                        self.assertEqual(target.read_text(), source.read_text())
                        raise RuntimeError("simulated transaction failure")
                if kind == "file":
                    self.assertEqual(target.read_text(), "original\n")
                    self.assertEqual(target.stat().st_mode & 0o777, 0o640)
                elif kind == "symlink":
                    self.assertEqual(str(target.readlink()), "/run/nonexistent/resolv.conf")
                else:
                    self.assertFalse(target.exists())
                target.unlink(missing_ok=True)

    def test_interrupted_resolver_backup_is_never_overwritten(self):
        source = self.write("live-resolver", "nameserver 192.0.2.1\n")
        backup = self.write("etc/resolv.conf.devario-installer-backup", "original\n")
        with self.assertRaisesRegex(RuntimeError, "interrupted installer"):
            with update.target_resolver(self.root, source):
                self.fail("must not enter target")
        self.assertEqual(backup.read_text(), "original\n")

    def test_wrapper_only_runs_commands_in_target_and_restores_dns(self):
        self.write("var/lib/devario/systemd-boot-installed", "")
        resolver = self.write("etc/resolv.conf", "target resolver\n")
        source = self.write("live-resolver", "nameserver 192.0.2.1\n")
        original = update.target_resolver
        events = []

        def run(args, **kwargs):
            events.append(args)
            if args[0] == "chroot":
                self.assertEqual(args[1], str(self.root))
                self.assertEqual(resolver.read_text(), source.read_text())
                self.assertIn("HOME=/root", args)
                self.assertIn("-i", args)
                self.assertEqual(args[-2:], [update.HELPER, "--run-target"])
                raise subprocess.CalledProcessError(1, args)

        with patch.object(update, "target_resolver", side_effect=lambda root: original(root, source)), \
                patch.object(update.subprocess, "run", side_effect=run), \
                self.assertRaises(subprocess.CalledProcessError):
            update.run_target(self.root)
        self.assertEqual([e[0] for e in events], ["findmnt", "chroot"])
        self.assertEqual(resolver.read_text(), "target resolver\n")
        self.assertFalse((self.root / "run/devario-installer-update/active").exists())

    def test_refuses_live_root_and_unprepared_target(self):
        with patch.object(update.subprocess, "run") as run:
            for root in (Path("/"), self.root):
                with self.assertRaises(RuntimeError):
                    update.run_target(root)
            with self.assertRaises(RuntimeError):
                update.update_target()
            run.assert_not_called()

    def transaction(self, failure=None, sync_failures=0, no_updates=False):
        runtime = self.root / "run/update"
        self.write("run/update/active", "")
        marker = self.write("boot-installed", "")
        evidence = self.root / "evidence"
        dbdir = self.root / "databases"
        self.write("databases/core.db", "signed metadata")
        events = []
        sync_attempts = 0
        inventories = 0
        real_path = Path

        def mapped_path(path):
            return dbdir if path == "/var/lib/shelly/sync" else real_path(path)

        def run(args, **kwargs):
            nonlocal sync_attempts, inventories
            events.append(args)
            if args[:2] == ["shelly", "sync"]:
                sync_attempts += 1
                if sync_attempts <= sync_failures:
                    raise subprocess.CalledProcessError(1, args)
            if failure and failure in args:
                if hasattr(kwargs.get("stderr"), "write"):
                    kwargs["stderr"].write("signature, disk-space or hook error\n")
                raise subprocess.CalledProcessError(1, args)
            if args[:2] == ["shelly", "list"]:
                inventories += 1
                return SimpleNamespace(stdout=json.dumps([{"Name": "kernel", "Version":
                    "1-1" if inventories == 1 or no_updates else "2-1"}]))
            return SimpleNamespace(stdout="")

        with patch.object(update, "RUNTIME", runtime), patch.object(update, "EVIDENCE", evidence), \
                patch.object(update, "BOOT_MARKER", marker), patch.object(update, "Path", side_effect=mapped_path), \
                patch.object(update.subprocess, "run", side_effect=run):
            if failure or sync_failures >= 3:
                with self.assertRaisesRegex(RuntimeError, "Installation is incomplete"), \
                        patch.object(update.sys, "stderr"):
                    update.update_target()
                self.assertEqual(json.loads((evidence / "result.json").read_text())["status"], "failed")
            else:
                update.update_target()
                result = json.loads((evidence / "result.json").read_text())
                self.assertEqual(result["status"], "complete")
                self.assertIn("core.db", result["databases"])
                for name in ("packages-before.json", "packages-after.json"):
                    self.assertTrue(json.loads((evidence / name).read_text()))
                self.assertEqual(json.loads((runtime / "config/shelly/config.json").read_text()),
                                 {"NativePackageBackend": "rlpm"})
        return events

    def test_updates_and_no_updates_both_verify_drivers_and_boot(self):
        for no_updates in (False, True):
            with self.subTest(no_updates=no_updates):
                events = self.transaction(no_updates=no_updates)
                upgrade = events.index(["shelly", "upgrade", "standard", "--no-confirm"])
                verify = events.index(["/usr/lib/devario/configure-target-nvidia", "--configure-updated"])
                boot = events.index(["/usr/lib/devario/boot-update"])
                self.assertLess(upgrade, verify)
                self.assertLess(verify, boot)
                self.assertEqual(events[-1], ["gpgconf", "--homedir", "/etc/shelly.d/gnupg", "--kill", "all"])

    def test_failures_stop_the_pipeline_without_retrying_transactions(self):
        for failure in ("init", "populate", "sync", "upgrade", "--configure-updated", "/usr/lib/devario/boot-update"):
            with self.subTest(failure=failure):
                events = self.transaction(failure=failure)
                self.assertIn(failure, events[-2])
                self.assertEqual(events[-1][0], "gpgconf")
                self.assertEqual(sum(failure in e for e in events), 3 if failure == "sync" else 1)

    def test_agent_cleanup_failure_prevents_success(self):
        self.transaction(failure="gpgconf")

    def test_sync_retries_are_bounded(self):
        self.assertEqual(sum("sync" in e for e in self.transaction(sync_failures=2)), 3)
        events = self.transaction(sync_failures=3)
        self.assertFalse(any("upgrade" in e for e in events))

    def test_calamares_requires_updates_last_and_connectivity_before_partitioning(self):
        import yaml
        settings = yaml.safe_load((PROFILE / "airootfs/etc/calamares/settings.conf").read_text())
        sequence = next(step["exec"] for step in settings["sequence"] if "exec" in step)
        self.assertLess(sequence.index("shellprocess@update_preflight"), sequence.index("partition"))
        self.assertEqual(sequence[-3:], ["services-systemd", "shellprocess@update_target", "umount"])
        self.assertLess(sequence.index("shellprocess@systemd_boot"), sequence.index("shellprocess@update_target"))
        for name, command in (("update_preflight", update.HELPER + " --preflight"),
                              ("update_target", update.HELPER + ' --target "${ROOT}"')):
            instance = next(i for i in settings["instances"] if i["id"] == name)
            self.assertEqual(instance["module"], "shellprocess")
            config = yaml.safe_load((PROFILE / "airootfs/etc/calamares/modules" / instance["config"]).read_text())
            self.assertTrue(config["dontChroot"])
            self.assertFalse(config["verbose"])
            self.assertEqual(config["script"], [command])
        welcome = yaml.safe_load((PROFILE / "airootfs/etc/calamares/modules/welcome.conf").read_text())
        self.assertIn("internet", welcome["requirements"]["required"])
        self.assertEqual(json.loads((PROFILE / "profile.json").read_text())["permissions"][update.HELPER], "755")


if __name__ == "__main__":
    unittest.main()
