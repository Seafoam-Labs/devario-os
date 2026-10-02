#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check packaged branding consistency and generation behavior."""
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest
import xml.etree.ElementTree as ET
import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("render_theme", ROOT / "scripts/render-calamares-theme.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


def luminance(color):
    values = [int(color[n:n+2], 16) / 255 for n in (1, 3, 5)]
    values = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in values]
    return sum(a * b for a, b in zip(values, (0.2126, 0.7152, 0.0722)))


class ThemeTests(unittest.TestCase):
    def test_generated_theme_is_current(self):
        for name, content in renderer.render().items():
            self.assertEqual((renderer.DESTINATION / name).read_text(), content, name)

    def test_single_branding_source(self):
        descriptors = list((ROOT / "iso").rglob("branding/devario/branding.desc"))
        self.assertEqual(descriptors, [renderer.DESTINATION / "branding.desc"])
        settings = yaml.safe_load((ROOT / "iso/airootfs/etc/calamares/settings.conf").read_text())
        self.assertEqual(settings["branding"], "devario")

    def test_assets_and_palette_roles_match(self):
        for variant in ("dark", "light"):
            files = renderer.render(variant=variant)
            desc = yaml.safe_load(files["branding.desc"])
            config = json.loads(files["theme.json"])
            for asset in [*desc["images"].values(), desc["slideshow"], "calamares-sidebar.qml"]:
                self.assertIn(asset, files)
            for name, content in files.items():
                if name.endswith(".svg"):
                    ET.fromstring(content)
            self.assertEqual(desc["uploadServer"]["type"], "none")
            self.assertEqual(desc["style"]["SidebarTextCurrent"], config["palette"]["onContainer"])
            self.assertEqual(json.loads(files["Theme.js"].split("var theme = ", 1)[1].rstrip(";\n")), config)
            unresolved = re.findall(r"@[A-Za-z_]+@", files["stylesheet.qss"])
            self.assertEqual(unresolved, ["@BRANDING_DIR@"])

    def test_readable_text_contrast(self):
        for variant in ("dark", "light"):
            palette = json.loads(renderer.render(variant=variant)["theme.json"])["palette"]
            for text, surface in (("text", "surface"), ("text", "low"), ("secondary", "container"),
                                  ("onPrimary", "primary"), ("onContainer", "primaryContainer"),
                                  ("error", "errorContainer")):
                a, b = sorted([luminance(palette[text]), luminance(palette[surface])])
                self.assertGreaterEqual((b + 0.05) / (a + 0.05), 4.5, (variant, text, surface))

    def test_reduced_motion_reaches_both_toolkits(self):
        files = renderer.render(reduced_motion=True)
        self.assertEqual(json.loads(files["theme.json"])["motionMs"], 0)
        self.assertIn('"motionMs": 0', files["Theme.js"])
        self.assertIn("Pearl.theme.motionMs > 0", files["show.qml"])

    def test_bad_palette_rejected(self):
        tokens = json.loads((renderer.SOURCE / "tokens.json").read_text())
        tokens["palettes"]["dark"]["text"] = "not a color"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "tokens.json").write_text(json.dumps(tokens))
            with self.assertRaises(ValueError):
                renderer.render(source=root)


if __name__ == "__main__":
    unittest.main()
