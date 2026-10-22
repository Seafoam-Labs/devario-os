#!/usr/bin/env python3
"""Adopt legacy ISO files before installing the integration and desktop packages.

Run from this complete recipe directory. Defaults to a read-only inspection.
This is deliberately separate from install hooks: conflicts precede hooks.
"""
import argparse
import configparser
from datetime import datetime, timezone
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile

PACKAGE = "devario-system-integration"
LEGACY = "devario-aqueous-desktop"


def destinations(manifest):
    result = []
    for line in manifest.read_text().splitlines():
        mode, source, destination = line.split("\t")
        path = Path(destination)
        if path.is_absolute() or ".." in path.parts or not path.parts:
            raise ValueError(f"Unsafe manifest destination: {destination}")
        if destination in result:
            raise ValueError(f"Duplicate manifest destination: {destination}")
        result.append(destination)
    return result


def section(path, name):
    lines = path.read_text().splitlines()
    marker = f"%{name}%"
    if lines.count(marker) != 1:
        raise ValueError(f"Missing or duplicate {marker} in {path}")
    result = []
    for line in lines[lines.index(marker) + 1:]:
        if not line:
            break
        result.append(line)
    return result


def ownership(database):
    local = database / "local"
    if not local.is_dir():
        raise ValueError(f"No installed package database at {local}")
    if (database / "db.lck").exists():
        raise ValueError("Another package transaction is running; retry when it finishes")
    owners = {}
    for entry in local.iterdir():
        if not entry.is_dir():
            continue
        names = section(entry / "desc", "NAME")
        if len(names) != 1:
            raise ValueError(f"Invalid package name in {entry}")
        for filename in section(entry / "files", "FILES"):
            owners.setdefault(filename, set()).add(names[0])
    return owners


def unowned_files(root, paths, owners):
    result = []
    for relative in paths:
        path = root / relative
        for parent in path.parents:
            if parent == root:
                break
            if parent.is_symlink():
                raise ValueError(f"Refusing symlinked parent: {parent}")
        if not os.path.lexists(path):
            continue
        if not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError(f"Expected a regular file: {path}")
        claimed = owners.get(relative, set())
        if claimed - {PACKAGE, LEGACY}:
            raise ValueError(f"{path} belongs to another package: {', '.join(sorted(claimed))}")
        if not claimed:
            result.append(relative)
    return result


def adopt(root, paths, backup, install):
    """Back up before moving any file; restore missing files even on interruption.

    Existing files left by a partially completed transaction are never replaced.
    All original bytes and modes remain available in the persistent backup.
    """
    for relative in paths:
        target = backup / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / relative, target)
        info = (root / relative).stat()
        if os.geteuid() == 0:
            os.chown(target, info.st_uid, info.st_gid)
    try:
        for relative in paths:
            (root / relative).unlink()
        install()
    finally:
        for relative in paths:
            original = root / relative
            if not os.path.lexists(original):
                shutil.copy2(backup / relative, original)
                info = (backup / relative).stat()
                if os.geteuid() == 0:
                    os.chown(original, info.st_uid, info.st_gid)


def checked_config(path):
    config = configparser.ConfigParser(strict=False, allow_no_value=True,
                                       interpolation=None, inline_comment_prefixes=("#",))
    config.read_string(path.read_text())
    # Keep ownership inspection and the install command on the same database.
    # More elaborate site configurations need an explicit administrator migration.
    if any("include" in config[section] for section in config.sections()):
        raise ValueError("Include directives need a site-specific migration")
    options = config["options"]
    if options.get("rootdir", "/").rstrip("/") != "":
        raise ValueError("This migration only supports the running system root")
    if options.get("dbpath", "/var/lib/shelly").rstrip("/") != "/var/lib/shelly":
        raise ValueError("Expected Devario's /var/lib/shelly database")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="back up overlay files and install packages")
    parser.add_argument("--config", type=Path, default=Path("/etc/shelly.conf"))
    args = parser.parse_args()
    checked_config(args.config)
    root = Path("/")
    paths = destinations(Path(__file__).with_name("files.tsv"))
    owners = ownership(Path("/var/lib/shelly"))
    unowned = unowned_files(root, paths, owners)
    print("Unowned overlay files to back up and adopt:", flush=True)
    for relative in unowned:
        print(f"  /{relative}", flush=True)
    print("Package-owned files transfer through Shelly's normal transaction.", flush=True)
    if not args.apply:
        print("Inspection only. Re-run with sudo and --apply after publishing both packages.")
        return
    if os.geteuid() != 0:
        raise ValueError("--apply requires root")
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"Migration interrupted by signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    backup_parent = Path("/var/lib/devario/migrations")
    backup_parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    prefix = "system-integration-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
    backup = Path(tempfile.mkdtemp(prefix=prefix, dir=backup_parent))
    print(f"Original files will remain in {backup}", flush=True)
    adopt(root, unowned, backup, lambda: subprocess.run(
        ["shelly", "--config", str(args.config.resolve()), "install", "standard",
         PACKAGE, "devario-desktop"], check=True))
    # Also detect cancellation or a partial transaction that returned success.
    installed = ownership(Path("/var/lib/shelly"))
    if any(installed.get(path) != {PACKAGE} for path in paths):
        raise ValueError(f"Package adoption incomplete; original files are backed up in {backup}")
    print("Integration files are now package-owned. Review saved local changes and reboot.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, configparser.Error, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
