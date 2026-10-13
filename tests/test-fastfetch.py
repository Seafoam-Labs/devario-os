#!/usr/bin/env python3
"""Exercise welcome hooks on real pseudoterminals and default config discovery."""

import errno
import json
import os
from pathlib import Path
import pty
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
OVERLAY = ROOT / "iso/late-airootfs"
ASSETS = OVERLAY / "usr/share/devario/fastfetch"


class FastfetchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.env = dict(os.environ, XDG_CONFIG_HOME=str(self.directory / "user"),
                        XDG_CONFIG_DIRS=str(self.directory / "system"), TERM="xterm-256color")
        self.env.pop("DEVARIO_FASTFETCH_TTY", None)
        self.env.pop("DEVARIO_FASTFETCH_SHOWN", None)
        Path(self.env["XDG_CONFIG_HOME"]).mkdir()

    def shell_run(self, shell, script, terminal=True, marker=None, term="xterm-256color", interactive=True):
        binary = shutil.which(shell)
        if binary is None:
            self.skipTest(f"{shell} is not installed")
        env = dict(self.env, TERM=term)
        if marker is not None:
            env["DEVARIO_FASTFETCH_TTY"] = marker
        stub = self.directory / "fastfetch"
        stub.write_text("#!/bin/sh\nprintf 'FETCH_CALLED\\n'\n")
        stub.chmod(0o755)
        env["PATH"] = f"{self.directory}:{os.environ['PATH']}"
        args = [binary, "--noprofile", "--norc"] if shell == "bash" else [binary, "--no-config"]
        args += ["-ic" if interactive else "-c", script]
        if not terminal:
            return subprocess.run(args, env=env, capture_output=True, text=True, check=True, timeout=10).stdout
        master, slave = pty.openpty()
        try:
            result = subprocess.run(args, env=env, stdin=subprocess.DEVNULL,
                                    stdout=slave, stderr=slave, timeout=10)
            result.check_returncode()
            os.close(slave)
            slave = None
            chunks = []
            while True:
                try:
                    data = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not data:
                    break
                chunks.append(data)
            return b"".join(chunks).decode()
        finally:
            os.close(master)
            if slave is not None:
                os.close(slave)

    def test_terminal_lifecycle(self):
        hooks = {"bash": OVERLAY / "etc/skel/.bashrc",
                 "fish": OVERLAY / "etc/skel/.config/fish/config.fish"}
        for shell, hook in hooks.items():
            with self.subTest(shell=shell):
                source = f"source {hook}"
                # Same-terminal repeats and nested shells share the marker.
                nested = (f"bash --noprofile --norc -ic '{source}'" if shell == "bash"
                          else f"fish --no-config -ic '{source}'")
                self.assertEqual(self.shell_run(shell, f"{source}; {source}; {nested}").count("FETCH_CALLED"), 1)
                # A new terminal must ignore the marker inherited from an old one.
                self.assertEqual(self.shell_run(shell, source, marker="/dev/pts/old").count("FETCH_CALLED"), 1)
                self.assertNotIn("FETCH_CALLED", self.shell_run(shell, source, terminal=False))
                self.assertNotIn("FETCH_CALLED", self.shell_run(shell, source, term="dumb"))
                self.assertNotIn("FETCH_CALLED", self.shell_run(shell, f"{source}; true", interactive=False))

    @unittest.skipUnless(shutil.which("fastfetch"), "fastfetch is not installed")
    def test_config_paths_logos_and_user_override(self):
        link = OVERLAY / "etc/xdg/fastfetch/config.jsonc"
        self.assertEqual(link.resolve(), ASSETS / "config.jsonc")
        config = json.loads(link.read_text())
        default_logo = OVERLAY / config["logo"]["source"].lstrip("/")
        self.assertEqual(default_logo.read_bytes(), (ASSETS / "fish-bold.txt").read_bytes())
        system_dir = Path(self.env["XDG_CONFIG_DIRS"]) / "fastfetch"
        system_dir.mkdir(parents=True)
        paths = subprocess.check_output(["fastfetch", "--list-config-paths"], env=self.env, text=True)
        self.assertIn("/etc/xdg/fastfetch/", paths)
        self.assertIn(str(system_dir), paths)
        config["modules"] = [{"type": "custom", "key": "OS", "format": "Devario preview"}]
        for logo in ["devario-fish", "fish-striped", "fish-compact", "fish-bold"]:
            with self.subTest(logo=logo):
                config["logo"]["source"] = str(ASSETS / f"{logo}.txt")
                (system_dir / "config.jsonc").write_text(json.dumps(config))
                # Load the staged system file explicitly: the developer may have
                # ~/.config/fastfetch, which takes precedence over system defaults.
                result = subprocess.run(["fastfetch", "--config", str(system_dir / "config.jsonc"), "--pipe", "false"], env=self.env,
                                        capture_output=True, text=True, check=True, timeout=10)
                self.assertIn("D E V A R I O", result.stdout)
                self.assertIn("Devario preview", result.stdout)
                self.assertEqual(result.stderr, "")
        user_dir = Path(self.env["XDG_CONFIG_HOME"]) / "fastfetch"
        user_dir.mkdir(parents=True)
        (user_dir / "config.jsonc").write_text(json.dumps({"logo": {"type": "none"},
            "modules": [{"type": "custom", "format": "PERSONAL_CONFIG"}]}))
        result = subprocess.run(["fastfetch"], env=self.env, capture_output=True,
                                text=True, check=True, timeout=10)
        self.assertIn("PERSONAL_CONFIG", result.stdout)
        self.assertNotIn("Devario preview", result.stdout)


if __name__ == "__main__":
    unittest.main()
