#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Extract factual PCI IDs from a reviewed NVIDIA open-module README."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def extract(readme, version):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Invalid NVIDIA driver version")
    text = readme.decode("utf-8")
    if not re.search(r"\bversion\s+" + re.escape(version) + r"\.", text):
        raise ValueError("README version does not match the requested driver")
    section = text.split("## Compatible GPUs\n", 1)[1].split("\n## ", 1)[0]
    devices = set()
    for line in section.splitlines():
        fields = line.split("|")
        if len(fields) != 4:
            continue
        value = fields[2].strip()
        if re.fullmatch(r"[0-9A-Fa-f]{4}(?: [0-9A-Fa-f]{4} [0-9A-Fa-f]{4})?", value):
            devices.add(value.lower())
    if not devices:
        raise ValueError("No compatible GPU IDs found")
    return {
        "driverVersion": version,
        "source": f"https://github.com/NVIDIA/open-gpu-kernel-modules/blob/{version}/README.md",
        "sourceSha256": hashlib.sha256(readme).hexdigest(),
        "pciIds": sorted(devices),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("readme", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_text(json.dumps(extract(args.readme.read_bytes(), args.version), indent=2) + "\n")
