#!/usr/bin/env python3
"""Hash an exact filesystem closure without following symlinks."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def file_digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def metadata(path: Path) -> dict[str, object]:
    info = path.lstat()
    attributes = []
    for name in sorted(os.listxattr(path, follow_symlinks=False)):
        value = os.getxattr(path, name, follow_symlinks=False)
        attributes.append(
            {
                "name": name,
                "size": len(value),
                "sha256": hashlib.sha256(value).hexdigest(),
            }
        )
    return {
        "permissions": f"{stat.S_IMODE(info.st_mode):04o}",
        "uid": info.st_uid,
        "gid": info.st_gid,
        "xattrs": attributes,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--exclude", action="append", default=[])
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    excluded = {value.strip("/") for value in args.exclude}
    entries: list[dict[str, object]] = []
    try:
        for directory, dirnames, filenames in os.walk(root, followlinks=False):
            relative_dir = Path(directory).relative_to(root).as_posix()
            if relative_dir == ".":
                relative_dir = ""
            dirnames[:] = sorted(
                name
                for name in dirnames
                if "/".join(filter(None, (relative_dir, name))) not in excluded
            )
            filenames.sort()
            for name in list(dirnames):
                path = Path(directory) / name
                if path.is_symlink():
                    dirnames.remove(name)
                    filenames.append(name)
            if relative_dir:
                directory_path = Path(directory)
                entries.append({"path": relative_dir, "type": "directory", **metadata(directory_path)})
            for name in sorted(filenames):
                path = Path(directory) / name
                relative = path.relative_to(root).as_posix()
                if relative in excluded:
                    continue
                mode = path.lstat().st_mode
                if stat.S_ISLNK(mode):
                    entries.append({"path": relative, "type": "symlink", "target": os.readlink(path), **metadata(path)})
                elif stat.S_ISREG(mode):
                    entries.append(
                        {
                            "path": relative,
                            "type": "file",
                            "size": path.stat().st_size,
                            "sha256": file_digest(path),
                            **metadata(path),
                        }
                    )
                else:
                    raise ValueError(f"special entry in closure: {relative}")
        encoded = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
        print(hashlib.sha256(encoded).hexdigest())
    except (OSError, ValueError) as error:
        print(f"Tree-closure error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
