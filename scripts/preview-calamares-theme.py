#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture actual Calamares pages using view-only configurations and no system bus.

Requires a compiled Calamares tree and the test-only capture library built by
 tests/test-calamares-theme.sh. These are UI previews, not installation tests.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "out/calamares-theme/pages")
    parser.add_argument("--branding", type=Path, default=ROOT / "iso/airootfs/usr/share/calamares/branding/devario")
    args = parser.parse_args()
    build = args.build.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    library = ROOT / "out/calamares-theme/build/libpearl-capture.so"
    if not library.is_file():
        parser.error("Build the appearance test harness first")
    with tempfile.TemporaryDirectory(prefix="devario-calamares-preview-") as temp:
        config = Path(temp)
        shutil.copytree(ROOT / "iso/airootfs/etc/calamares/modules", config / "modules")
        shutil.copytree(args.branding, config / "branding/devario")
        (config / "qml").symlink_to(build / "src/qml", target_is_directory=True)
        # Host /etc/os-release is deliberately not used as the preview identity.
        desc = config / "branding/devario/branding.desc"
        data = yaml.safe_load(desc.read_text())
        data["strings"].update(version="Preview", shortVersion="Preview", versionedName="Devario Preview")
        desc.write_text(yaml.safe_dump(data, sort_keys=False))
        settings = yaml.safe_load((ROOT / "iso/airootfs/etc/calamares/settings.conf").read_text())
        settings.pop("instances", None)
        settings["modules-search"] = [str(build / "src/modules")]
        settings["sequence"] = []
        # Prevent live-system changes, network checks and restart actions.
        for name, changes in {"locale": {"adjustLiveTimezone": False, "geoip": {"style": "none"}},
                              "keyboard": {"useLocale1": False, "configure": {"xkb": False, "kwin": False}},
                              "finished": {"restartNowCommand": "/usr/bin/true", "restartNowMode": "never"}}.items():
            path = config / "modules" / (name + ".conf")
            module = yaml.safe_load(path.read_text())
            module.update(changes)
            path.write_text(yaml.safe_dump(module))
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software",
                   DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(config / "no-system-bus"),
                   XDG_CACHE_HOME=str(config / "cache"), LD_PRELOAD=str(library))
        for page in ("welcome", "locale", "keyboard", "partition", "users", "summary", "finished"):
            settings["sequence"] = [{"show": [page]}]
            (config / "settings.conf").write_text(yaml.safe_dump(settings, sort_keys=False))
            env["DEVARIO_CAPTURE_PATH"] = str(output / (page + ".png"))
            with (output / (page + ".log")).open("w") as log:
                subprocess.run([str(build / "calamares"), "-d", "-c", str(config)],
                               env=env, cwd=build, stdout=log, stderr=subprocess.STDOUT, timeout=20, check=True)
            evidence = (output / (page + ".log")).read_text()
            expected = f'ViewModule "{page}@{page}" loading complete.'
            if expected not in evidence or "Devario Pearl appearance loaded from" not in evidence:
                raise RuntimeError(f"{page}: expected module and theme did not load")
            if any(error in evidence for error in ("ReferenceError:", "TypeError:", "is not a type")):
                raise RuntimeError(f"{page}: QML error; inspect the capture log")
            print("Captured " + page, flush=True)


if __name__ == "__main__":
    main()
