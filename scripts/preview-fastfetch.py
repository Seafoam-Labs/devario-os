#!/usr/bin/env python3
"""Preview the included fish logos without installing system configuration."""

import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "iso/late-airootfs/usr/share/devario/fastfetch"
OPTIONS = {"striped": "Striped Devario", "compact": "Compact outline", "bold": "Bold silhouette (default)"}


def configuration(option, sample=False):
    config = json.loads((ASSETS / "config.jsonc").read_text())
    config["logo"]["source"] = str(ASSETS / f"fish-{option}.txt")
    if sample:
        # Illustrative values only; the installed configuration detects real data.
        values = [
            ("OS", "Devario OS x86_64"), ("Host", "Your computer"),
            ("Kernel", "Linux (Devario)"), ("Uptime", "12 mins"),
            ("Packages", "1248 (Shelly)"), ("Shell", "fish"),
            ("Display", "1920x1080 @ 60 Hz"), ("WM", "Aqueous (Wayland)"),
            ("Terminal", "Ghostty"), ("CPU", "AMD Ryzen 7"),
            ("GPU", "AMD Radeon Graphics"), ("Memory", "3.2 GiB / 16 GiB"),
            ("Disk (/)", "24 GiB / 512 GiB - btrfs"),
        ]
        config["modules"] = [{"type": "title", "format": "you@devario"}, "separator"] + [
            {"type": "custom", "key": key, "format": value} for key, value in values
        ]
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("option", choices=[*OPTIONS, "all"], nargs="?", default="all")
    parser.add_argument("--sample", action="store_true", help="use labeled illustrative system values")
    args = parser.parse_args()
    for option in OPTIONS if args.option == "all" else [args.option]:
        suffix = " (illustrative values)" if args.sample else " (this machine's values)"
        print(f"\n{OPTIONS[option]}{suffix}\n", flush=True)
        subprocess.run(
            ["fastfetch", "--config", "-", "--pipe", "false"],
            input=json.dumps(configuration(option, args.sample)), text=True, check=True,
        )


if __name__ == "__main__":
    main()
