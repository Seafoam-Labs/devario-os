#!/usr/bin/env python3
"""Render a release identity into a composed, development os-release file."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shlex
import stat
import sys


VERSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
KEY = re.compile(r"[A-Z][A-Z0-9_]*")


def parse_value(raw: str) -> str:
    try:
        values = shlex.split(raw, comments=False, posix=True)
    except ValueError as error:
        raise ValueError(f"invalid os-release value: {raw}") from error
    if len(values) != 1:
        raise ValueError(f"invalid os-release value: {raw}")
    return values[0]


def quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render(path: Path, edition: str, variant: str, release_version: str) -> None:
    if len(release_version) > 64 or VERSION.fullmatch(release_version) is None:
        raise ValueError("release version does not match the canonical 1-64 character pattern")
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or path.is_symlink():
        raise ValueError("os-release must be a regular, non-symlink file")
    raw_lines = path.read_text(encoding="utf-8").splitlines()
    entries: list[tuple[str, str]] = []
    parsed: dict[str, str] = {}
    for number, line in enumerate(raw_lines, 1):
        if not line or line.startswith("#") or "=" not in line:
            raise ValueError(f"unsupported os-release line {number}")
        key, raw = line.split("=", 1)
        if KEY.fullmatch(key) is None or key in parsed:
            raise ValueError(f"invalid or duplicate os-release key at line {number}")
        value = parse_value(raw)
        if "\n" in value or "\x00" in value:
            raise ValueError(f"unsafe os-release value at line {number}")
        parsed[key] = value
        entries.append((key, raw))
    required = {"NAME", "PRETTY_NAME", "ID", "BUILD_ID", "VARIANT", "VARIANT_ID"}
    if not required.issubset(parsed):
        raise ValueError("composed os-release lacks required identity fields")
    if parsed["VARIANT_ID"] != edition or parsed["VARIANT"] != variant:
        raise ValueError("composed os-release identity differs from edition metadata")
    if "Development" not in parsed["PRETTY_NAME"]:
        raise ValueError("release renderer expected an unmodified development identity")

    result: list[str] = []
    inserted = False
    replaced = {"PRETTY_NAME", "VERSION", "VERSION_ID", "BUILD_ID"}
    for key, raw in entries:
        if key in replaced:
            continue
        result.append(f"{key}={raw}")
        if key == "NAME":
            result.extend(
                (
                    f"PRETTY_NAME={quote(parsed['NAME'] + ' ' + release_version)}",
                    f"VERSION={quote(release_version)}",
                    f"VERSION_ID={quote(release_version)}",
                    f"BUILD_ID={quote(release_version)}",
                )
            )
            inserted = True
    if not inserted:
        raise ValueError("os-release has no NAME insertion point")
    temporary = path.with_name(f".{path.name}.release.tmp")
    temporary.write_text("\n".join(result) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o644)
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", type=Path, required=True)
    parser.add_argument("--edition", required=True)
    parser.add_argument("--variant", required=True)
    parser.add_argument("--release-version", required=True)
    args = parser.parse_args()
    try:
        render(args.file, args.edition, args.variant, args.release_version)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Release os-release error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
