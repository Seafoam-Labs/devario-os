#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check installed-user startup without changing the host or starting services."""
import json
import os
from pathlib import Path
import tempfile
from types import ModuleType
import unittest
from unittest.mock import patch

import yaml

PROJECT = Path(__file__).resolve().parents[1]
PROFILE = Path(os.environ.get("DEVARIO_PROFILE_DIR", PROJECT / "iso"))
HELPER = PROFILE / "airootfs/usr/lib/devario/configure-target-shelly-tray"
tray = ModuleType("configure_target_shelly_tray")
exec(compile(HELPER.read_text(), str(HELPER), "exec"), tray.__dict__)


class TrayTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="devario-tray-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "home/alex"
        self.home.mkdir(parents=True)
        (self.root / "etc").mkdir()
        (self.root / "etc/passwd").write_text(
            "root:x:0:0:root:/root:/bin/bash\n"
            "alex:x:1234:2345:Alex:/home/alex:/usr/bin/fish\n")
        self.binary = self.root / "usr/bin/shelly-notifications"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_text("#!/bin/sh\nexit 0\n")
        self.binary.chmod(0o755)
        self.settings = self.home / ".config/shelly/settings.json"
        self.service = self.home / ".config/systemd/user/shelly-notifications.service"
        self.link = self.service.parent / "graphical-session.target.wants" / self.service.name
        # Ownership calls are verified without requiring root in the test runner.
        self.chown = self.enterContext(patch.object(tray.os, "chown"))
        self.fchown = self.enterContext(patch.object(tray.os, "fchown"))

    def seed(self, content):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(content)

    def configure(self):
        tray.configure(self.root, "alex")

    def test_new_user_starts_at_graphical_login_with_user_owned_files(self):
        self.configure()
        self.assertEqual(json.loads(self.settings.read_text()),
                         {"TrayEnabled": True, "TrayAutoStart": True})
        self.assertIn("ExecStart=/usr/bin/shelly-notifications\n", self.service.read_text())
        self.assertIn("PartOf=graphical-session.target\n", self.service.read_text())
        self.assertEqual(self.link.resolve(), self.service)
        self.assertEqual(os.readlink(self.link), "../shelly-notifications.service")
        self.chown.assert_any_call(self.link, 1234, 2345, follow_symlinks=False)
        self.assertEqual(self.fchown.call_count, 2)
        for call in self.fchown.call_args_list:
            self.assertEqual(call.args[1:], (1234, 2345))
        for path in (self.settings, self.service):
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)
        for call in self.chown.call_args_list:
            self.assertTrue(call.args[0].is_relative_to(self.home))
            self.assertEqual(call.args[1:], (1234, 2345))
        self.assertFalse((self.root / "etc/skel").exists())
        self.assertFalse((self.root / "etc/systemd").exists())
        before = (self.settings.read_bytes(), self.service.read_bytes())
        self.configure()
        self.assertEqual(before, (self.settings.read_bytes(), self.service.read_bytes()))

    def test_preserves_other_preferences_and_custom_service(self):
        self.seed('{"Culture":"fr","TrayCheckIntervalHours":6,"NewInstall":false}')
        self.service.parent.mkdir(parents=True)
        self.service.write_text(tray.SERVICE + "# User customization\n")
        self.configure()
        preferences = json.loads(self.settings.read_text())
        self.assertEqual(preferences["Culture"], "fr")
        self.assertEqual(preferences["TrayCheckIntervalHours"], 6)
        self.assertIs(preferences["NewInstall"], False)
        self.assertTrue(self.service.read_text().endswith("# User customization\n"))

    def test_existing_opt_out_is_preserved(self):
        for key in ("TrayEnabled", "TrayAutoStart"):
            with self.subTest(key=key):
                self.seed(json.dumps({key: False}))
                self.configure()
                self.assertIs(json.loads(self.settings.read_text())[key], False)
                self.assertFalse(self.service.exists())
                self.assertFalse(self.link.is_symlink())

    def test_invalid_settings_are_not_overwritten(self):
        for content in ("{broken", "[]", '{"TrayEnabled":"true"}'):
            with self.subTest(content=content):
                self.seed(content)
                with self.assertRaises(ValueError):
                    self.configure()
                self.assertEqual(self.settings.read_text(), content)
                self.assertFalse(self.service.exists())

    def test_missing_binary_or_wrong_user_fails_before_writing(self):
        for username in ("root", "missing"):
            with self.assertRaises(ValueError):
                tray.configure(self.root, username)
        self.binary.unlink()
        with self.assertRaises(ValueError):
            self.configure()
        self.assertFalse((self.home / ".config").exists())

    def test_symlink_cannot_redirect_settings_outside_selected_home(self):
        outside = self.root / "elsewhere"
        outside.mkdir()
        (self.home / ".config").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "Refusing symlink"):
            self.configure()
        self.assertEqual(list(outside.iterdir()), [])
        self.chown.assert_not_called()

    def test_installer_runs_in_target_after_users_and_updates(self):
        directory = PROFILE / "airootfs/etc/calamares"
        settings = yaml.safe_load((directory / "settings.conf").read_text())
        sequence = next(item["exec"] for item in settings["sequence"] if "exec" in item)
        name = "shellprocess@shelly_tray"
        self.assertEqual(sequence.count(name), 1)
        for prerequisite in ("users", "shellprocess@update_target"):
            self.assertLess(sequence.index(prerequisite), sequence.index(name))
        self.assertLess(sequence.index(name), sequence.index("umount"))
        instance = next(item for item in settings["instances"] if item["id"] == "shelly_tray")
        self.assertEqual(instance["module"], "shellprocess")
        module = yaml.safe_load((directory / "modules" / instance["config"]).read_text())
        self.assertIs(module["dontChroot"], False)
        self.assertEqual(module["script"], ['/usr/lib/devario/configure-target-shelly-tray "${USER}"'])
        permissions = json.loads((PROFILE / "profile.json").read_text())["permissions"]
        self.assertEqual(permissions["/usr/lib/devario/configure-target-shelly-tray"], "755")


if __name__ == "__main__":
    unittest.main()
