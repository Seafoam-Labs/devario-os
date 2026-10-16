#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the installer helper against isolated target filesystems."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
from types import ModuleType
import unittest
from unittest.mock import patch

import yaml

PROJECT = Path(__file__).resolve().parents[1]
PROFILE = Path(os.environ.get("DEVARIO_PROFILE_DIR", PROJECT / "iso"))
HELPER = PROFILE / "airootfs/usr/lib/devario/configure-target-keyboard"
keyboard = ModuleType("configure_target_keyboard")
exec(compile(HELPER.read_text(), str(HELPER), "exec"), keyboard.__dict__)


class KeyboardTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="devario-keyboard-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "target"
        self.root.mkdir()
        self.source = self.root / keyboard.XORG
        self.target = self.root / keyboard.INPUT

    def write(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def select(self, layout="fr", variant=None, options=None):
        lines = ['# Written by Calamares', 'Section "InputClass"',
                 '    Identifier "system-keyboard"', '    MatchIsKeyboard "on"',
                 '    Option "XkbModel" "pc105"', f'    Option "XkbLayout" {json.dumps(layout)}']
        if variant is not None:
            lines.append(f'    Option "XkbVariant" {json.dumps(variant)}')
        if options is not None:
            lines.append(f'    Option "XkbOptions" {json.dumps(options)}')
        self.write(self.source, "\n".join(lines + ['EndSection', '']))

    def run_helper(self, success=True):
        result = subprocess.run([sys.executable, "-I", str(HELPER), "--root", str(self.root)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if success else 1, result.stdout + result.stderr)
        return result

    def test_layouts_variants_options_and_readable_defaults(self):
        for layout, variant, options in (("fr", None, None), ("us", "", ""),
                                          ("fr", "oss", None), ("us", "dvorak", "caps:escape"),
                                          ("us,fr", ",oss", "grp:alt_shift_toggle,caps:escape")):
            with self.subTest(layout=layout, variant=variant):
                self.select(layout, variant, options)
                self.run_helper()
                self.assertEqual(tomllib.loads(self.target.read_text()), {"input": {
                    "xkb_layout": layout, "xkb_variant": variant or "", "xkb_options": options or ""}})
                self.assertEqual(self.target.stat().st_mode & 0o777, 0o644)
                # Aqueous's input parser requires bare section and key names.
                self.assertIn('[input]\nxkb_layout = ', self.target.read_text())

    def test_preserves_input_devices_rules_and_unrelated_toml_values(self):
        original = '''version = 1
title = "Keyboards"
timestamp = 2026-10-16T12:00:00Z
date = 2026-10-16
time = 12:00:00
empty = []
mixed = [1, { a = true }]
"dotted.key" = "value"
[input]
xkb_layout = "us"
xkb_variant = "dvorak"
xkb_options = "caps:escape"
repeat_rate = 35
num_lock_state = true
description = """First line
Second line"""
[input.touchpad]
tap = true
natural_scroll = false
accel = 0.25
[[input.tablet]]
id = "pen"
match_vendor = 0x056a
output = "DP-1"
[input.tablet.mapping]
region = [0.0, 1.0]
[[input.tablet]]
id = "other"
enabled = false
[gestures]
swipe = "workspace-next"
'''
        self.write(self.target, original)
        expected = tomllib.loads(original)
        expected["input"].update(xkb_layout="fr", xkb_variant="", xkb_options="")
        self.select()
        self.run_helper()
        self.assertEqual(tomllib.loads(self.target.read_text()), expected)
        self.assertIn("[[input.tablet]]", self.target.read_text())
        first = self.target.read_bytes()
        self.run_helper()
        self.assertEqual(self.target.read_bytes(), first)

    def test_adds_input_to_existing_config_and_normalizes_inline_table(self):
        for original in ('[gestures]\nswipe = "next"\n', 'input = { repeat_rate = 20 }\n',
                         'input.repeat_rate = 20\n', '[input.touchpad]\ntap = true\n'):
            with self.subTest(original=original):
                self.write(self.target, original)
                self.select()
                self.run_helper()
                expected = tomllib.loads(original)
                expected.setdefault("input", {}).update(xkb_layout="fr", xkb_variant="", xkb_options="")
                self.assertEqual(tomllib.loads(self.target.read_text()), expected)

    def test_only_selected_target_is_changed(self):
        live = self.root.parent / "live"
        self.write(live / keyboard.INPUT, '[input]\nxkb_layout = "us"\n')
        personal = self.root / "home/test/.config/aqueous/input.toml"
        self.write(personal, '[input]\nxkb_layout = "de"\n')
        console = self.root / "etc/vconsole.conf"
        self.write(console, "KEYMAP=not-an-xkb-layout\n")
        before = {p: p.read_bytes() for p in (live / keyboard.INPUT, personal, console)}
        self.select()
        before[self.source] = self.source.read_bytes()
        self.run_helper()
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertEqual(tomllib.loads(self.target.read_text())["input"]["xkb_layout"], "fr")

    def test_quotes_comments_and_shell_text_are_data(self):
        marker = self.root / "should-not-exist"
        value = f'caps:escape,# $(touch {marker}) `false` "quoted" \\path'
        self.select(options=value)
        self.source.write_text(self.source.read_text().replace('"XkbLayout" "fr"',
                                                              '"xkblayout" "fr" # selected'))
        self.run_helper()
        self.assertEqual(tomllib.loads(self.target.read_text())["input"]["xkb_options"], value)
        self.assertFalse(marker.exists())

    def test_bad_source_leaves_existing_configuration_intact(self):
        existing = '[input]\nxkb_layout = "de"\n'
        for source in (None, "", 'Section "InputClass"\nEndSection\n',
                       'Section "InputClass"\nOption "XkbLayout" ""\nEndSection\n',
                       'Section "InputClass"\nOption "XkbLayout" "fr"\n',
                       'Section "InputClass"\nOption "XkbLayout" "fr\nEndSection\n',
                       'Section "InputClass"\nOption "XkbLayout" "fr"\n'
                       'Option "XkbLayout" "us"\nEndSection\n',
                       'Section "InputClass"\nOption "XkbLayout" "fr"\nEndSection\n' * 2):
            with self.subTest(source=source):
                self.write(self.target, existing)
                if source is None:
                    self.source.unlink(missing_ok=True)
                else:
                    self.write(self.source, source)
                result = self.run_helper(success=False)
                self.assertIn("Devario keyboard: cannot configure", result.stderr)
                self.assertEqual(self.target.read_text(), existing)
                self.assertFalse(list(self.target.parent.glob(".input.toml.*")))

    def test_invalid_destination_fails_without_replacing_it(self):
        self.select()
        for source in ('[input\nxkb_layout = "us"\n', 'input = "wrong type"\n',
                       '[input]\nxkb_layout = "us"\nxkb_layout = "de"\n'):
            with self.subTest(source=source):
                self.write(self.target, source)
                self.run_helper(success=False)
                self.assertEqual(self.target.read_text(), source)

    def test_atomic_replace_failure_preserves_original_and_cleans_temporary_file(self):
        self.select()
        original = '[input]\nxkb_layout = "us"\n'
        self.write(self.target, original)
        with patch.object(keyboard.os, "replace", side_effect=OSError("simulated write failure")):
            with self.assertRaisesRegex(OSError, "simulated write failure"):
                keyboard.configure(self.root)
        self.assertEqual(self.target.read_text(), original)
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_installation_runs_in_target_after_update_before_unmount(self):
        directory = PROFILE / "airootfs/etc/calamares"
        settings = yaml.safe_load((directory / "settings.conf").read_text())
        sequence = next(item["exec"] for item in settings["sequence"] if "exec" in item)
        name = "shellprocess@keyboard_aqueous"
        self.assertEqual(sequence.count(name), 1)
        self.assertLess(sequence.index("keyboard"), sequence.index(name))
        self.assertLess(sequence.index("shellprocess@update_target"), sequence.index(name))
        self.assertLess(sequence.index(name), sequence.index("umount"))
        instance = next(item for item in settings["instances"] if item["id"] == "keyboard_aqueous")
        self.assertEqual(instance["module"], "shellprocess")
        module = yaml.safe_load((directory / "modules" / instance["config"]).read_text())
        self.assertIs(module["dontChroot"], False)
        self.assertEqual(module["script"], ["/usr/lib/devario/configure-target-keyboard"])
        permissions = json.loads((PROFILE / "profile.json").read_text())["permissions"]
        self.assertEqual(permissions["/usr/lib/devario/configure-target-keyboard"], "755")


if __name__ == "__main__":
    unittest.main()
