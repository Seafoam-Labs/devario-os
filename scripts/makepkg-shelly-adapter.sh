#!/usr/bin/env bash
set -euo pipefail

# makepkg always queries the installed package inventory while writing
# .BUILDINFO, even when dependency checks are disabled. This strict adapter
# serves that one read-only query through Shelly and rejects every transaction
# or dependency-resolution operation. It is not a general compatibility shim.
if (( $# != 1 )) || [[ "$1" != -Qi ]]; then
  echo "makepkg requested an unsupported package-manager operation: $*" >&2
  exit 64
fi

for command_name in shelly python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

shelly list standard --show-hidden --json | python3 -c '
import glob
import json
import platform
import sys


def read_sections(path):
    sections = {}
    key = None
    values = []
    with open(path, encoding="utf-8", errors="replace") as stream:
        for raw_line in stream:
            line = raw_line.rstrip("\n")
            if line.startswith("%") and line.endswith("%"):
                if key is not None:
                    sections[key] = values
                key = line.strip("%")
                values = []
            elif key is not None and line:
                values.append(line)
    if key is not None:
        sections[key] = values
    return sections


# Drain the Shelly JSON stream before doing filesystem work so the producer can
# complete even on hosts with a large installed-package inventory.
packages = json.load(sys.stdin)
if not isinstance(packages, list):
    packages = [packages]

# The Shelly JSON inventory intentionally omits architecture. Read that field
# from the same local ALPM database Shelly queried so makepkg can preserve its
# established .BUILDINFO schema without invoking another package manager.
architectures = {}
for description in glob.glob("/var/lib/shelly/local/*/desc"):
    fields = read_sections(description)
    name = (fields.get("NAME") or [None])[0]
    version = (fields.get("VERSION") or [None])[0]
    architecture = (fields.get("ARCH") or [None])[0]
    if name and version and architecture:
        architectures[(name, version)] = architecture

fallback_architecture = platform.machine() or "unknown"
for package in packages:
    name = package.get("Name")
    version = package.get("Version")
    if not name or not version:
        continue
    architecture = architectures.get((name, version), fallback_architecture)
    print(f"Name            : {name}")
    print(f"Version         : {version}")
    print(f"Architecture    : {architecture}")
'
