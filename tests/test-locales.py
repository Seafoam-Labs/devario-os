#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise locale catalog preservation and glibc's actual locale loading."""
import ast
import json
import locale
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import sys
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch

import yaml

PROJECT = Path(__file__).resolve().parents[1]
PROFILE = Path(os.environ.get("DEVARIO_PROFILE_DIR", PROJECT / "iso"))
HELPER = PROFILE / "airootfs/usr/lib/devario/check-target-locales"
check = runpy.run_path(str(HELPER))["check"]
CALAMARES = Path(os.environ.get("DEVARIO_CALAMARES_LOCALE_MODULE",
                               "/usr/lib/calamares/modules/localecfg/main.py"))


class LocaleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="devario-locales-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.config = self.root / "locale.conf"

    def test_checker_accepts_quotes_comments_and_mixed_settings(self):
        self.config.write_text('# Selected language\nLANG="C.UTF-8"\n'
                               "LC_TIME='C' # regional format\nLANGUAGE=de:en\n")
        previous = locale.setlocale(locale.LC_ALL)
        check(self.config)
        self.assertEqual(locale.setlocale(locale.LC_ALL), previous)

    def test_checker_reports_missing_locale_even_with_valid_lang(self):
        self.config.write_text("LANG=C.UTF-8\nLC_TIME=xx_MISSING.UTF-8\n")
        previous = locale.setlocale(locale.LC_ALL)
        with self.assertRaisesRegex(ValueError, "LC_TIME=xx_MISSING.UTF-8"):
            check(self.config)
        self.assertEqual(locale.setlocale(locale.LC_ALL), previous)

    def test_checker_fails_missing_or_malformed_configuration(self):
        for text in ("", "LC_TIME=C\n", "LANG=\n", "LANG='unterminated\n", "LANG=C extra\n"):
            with self.subTest(text=text):
                self.config.write_text(text)
                with self.assertRaises(ValueError):
                    check(self.config)
        self.config.unlink()
        with self.assertRaises(FileNotFoundError):
            check(self.config)

    def test_checker_cli_returns_failure_with_repair_guidance(self):
        self.config.write_text("LANG=xx_MISSING.UTF-8\n")
        result = subprocess.run([sys.executable, "-I", str(HELPER), "--config", str(self.config)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("LANG=xx_MISSING.UTF-8", result.stderr)
        self.assertIn("locale-gen", result.stderr)

    def test_installer_checks_target_immediately_after_localecfg(self):
        directory = PROFILE / "airootfs/etc/calamares"
        settings = yaml.safe_load((directory / "settings.conf").read_text())
        sequence = next(item["exec"] for item in settings["sequence"] if "exec" in item)
        self.assertEqual(sequence[sequence.index("localecfg") + 1], "shellprocess@check_locales")
        instance = next(item for item in settings["instances"] if item["id"] == "check_locales")
        self.assertEqual(instance["module"], "shellprocess")
        module = yaml.safe_load((directory / "modules" / instance["config"]).read_text())
        self.assertIs(module["dontChroot"], False)
        self.assertEqual(module["script"], ["/usr/lib/devario/check-target-locales"])
        permissions = json.loads((PROFILE / "profile.json").read_text())["permissions"]
        self.assertEqual(permissions["/usr/lib/devario/check-target-locales"], "755")
        for overlay in ("airootfs", "late-airootfs"):
            self.assertFalse((PROFILE / overlay / "etc/locale.gen").exists(),
                             "glibc must supply the complete locale catalog")

    @unittest.skipUnless(shutil.which("localedef") and Path("/usr/share/i18n/locales/de_DE").exists(),
                         "glibc locale sources and localedef are required")
    def test_real_german_locale_must_be_generated_before_checker_accepts_it(self):
        locales = self.root / "locales"
        locales.mkdir()
        # A private name keeps this test valid on hosts with German installed.
        name = "de_DE.UTF-8@devario_issue12_test"
        self.config.write_text(f"LANG={name}\nLC_TIME=C.UTF-8\n")
        environment = dict(os.environ, LOCPATH=str(locales), LC_ALL="C")
        command = [sys.executable, "-I", str(HELPER), "--config", str(self.config)]
        before = subprocess.run(command, env=environment, capture_output=True, text=True)
        self.assertEqual(before.returncode, 1, before.stdout + before.stderr)
        subprocess.run(["localedef", "--no-archive", "-i", "de_DE", "-f", "UTF-8",
                        str(locales / name)], check=True, capture_output=True)
        after = subprocess.run(command, env=environment, capture_output=True, text=True)
        self.assertEqual(after.returncode, 0, after.stdout + after.stderr)

    @unittest.skipUnless(CALAMARES.is_file(), "packaged Calamares localecfg module is required")
    def test_builder_catalog_allows_real_calamares_to_enable_selected_locales(self):
        # Execute the packaged Calamares rewrite functions without its embedded
        # libcalamares runtime. No reimplementation of locale matching here.
        tree = ast.parse(CALAMARES.read_text())
        selected = [node for node in tree.body
                    if isinstance(node, ast.FunctionDef) and node.name in
                    {"is_comment", "extract_locale", "rewrite_locale_gen"}
                    or isinstance(node, ast.Assign) and any(
                        getattr(target, "id", "").startswith("RE_") for target in node.targets)]
        namespace = {"re": re}
        exec(compile(ast.Module(body=selected, type_ignores=[]), str(CALAMARES), "exec"), namespace)
        rewrite = namespace["rewrite_locale_gen"]
        with tarfile.open(PROJECT / "tools/devario-iso-builder/devario-iso-builder.tar.gz") as archive:
            source = archive.extractfile("devario-iso-builder/builder.py").read()
        builder = types.ModuleType("builder")
        exec(compile(source, "builder.py", "exec"), builder.__dict__)
        catalog = self.root / "etc/locale.gen"
        catalog.parent.mkdir()
        # The exact broken ISO input from issue #12 reproduces its diagnostic.
        catalog.write_text("en_US.UTF-8 UTF-8\n")
        rewrite(catalog, catalog, {"LANG": "de_DE.UTF-8"})
        self.assertIn("# Missing: de_DE.UTF-8", catalog.read_text())
        for settings in ({"LANG": "de_DE.UTF-8"}, {"LANG": "en_US.UTF-8"},
                         {"LANG": "en_US.UTF-8", "LC_TIME": "de_DE.UTF-8"},
                         {"LANG": "fr_FR.UTF-8", "LC_TIME": "de_DE.UTF-8"}):
            with self.subTest(settings=settings):
                catalog.write_text("#en_US.UTF-8 UTF-8\n#de_DE.UTF-8 UTF-8\n#fr_FR.UTF-8 UTF-8\n")
                with patch.object(builder, "command"):
                    builder.configure_live_locale(self.root)
                rewrite(catalog, catalog, settings)
                for name in {*settings.values(), "en_US.UTF-8"}:
                    self.assertIn(f"{name} UTF-8", catalog.read_text().splitlines())
                self.assertNotIn("# Missing:", catalog.read_text())
                enabled = [line for line in catalog.read_text().splitlines()
                           if line and not line.startswith("#")]
                rewrite(catalog, catalog, settings)
                self.assertEqual([line for line in catalog.read_text().splitlines()
                                  if line and not line.startswith("#")], enabled)


if __name__ == "__main__":
    unittest.main()
