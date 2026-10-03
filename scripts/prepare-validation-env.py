#!/usr/bin/env python3
"""Prepare hash-locked validation wheels without installing system packages."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import sysconfig
import venv


LOCK = Path(__file__).with_name("validation-requirements.lock")


def default_cache() -> Path:
    if os.environ.get("DEVARIO_VALIDATION_CACHE"):
        return Path(os.environ["DEVARIO_VALIDATION_CACHE"])
    # Provisioned containers share this root-owned environment with build users.
    container = Path("/opt/devario/validation-python")
    if container.is_dir():
        return container
    if os.geteuid() == 0:
        return Path("/var/cache/devario/validation-python")
    return Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "devario/validation-python"


def identity() -> dict:
    return {"format": 1, "requirementsSha256": hashlib.sha256(LOCK.read_bytes()).hexdigest(),
            "python": sys.version, "cacheTag": sys.implementation.cache_tag,
            "platform": sysconfig.get_platform(), "abi": sysconfig.get_config_var("SOABI")}


def verify(environment: Path, expected: dict) -> bool:
    try:
        if json.loads((environment / "devario-validation.json").read_text()) != expected:
            return False
        packages = dict(re.findall(r"^([A-Za-z0-9_.-]+)==([^\s]+)", LOCK.read_text(), re.M))
        result = subprocess.run([str(environment / "bin/python3"), "-I", "-B", "-c", """
import importlib.metadata, json, sys
import yaml
from jsonschema import Draft202012Validator
assert sys.prefix != sys.base_prefix
for name, version in json.loads(sys.argv[1]).items():
    assert importlib.metadata.version(name) == version, name
Draft202012Validator({'type': 'integer'}).validate(1)
assert yaml.safe_load('ready: true')['ready'] is True
""", json.dumps(packages)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        return result.returncode == 0
    except (OSError, ValueError):
        return False


def pip(environment: Path, *args: str) -> None:
    subprocess.run([str(environment / "bin/python3"), "-I", "-B", "-m", "pip",
                    "--isolated", "--disable-pip-version-check", "--no-cache-dir", *args],
                   check=True, stdout=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", type=Path, default=default_cache())
    parser.add_argument("--wheelhouse", type=Path, default=os.environ.get("DEVARIO_VALIDATION_WHEELHOUSE"))
    parser.add_argument("--offline", action="store_true", default=os.environ.get("DEVARIO_VALIDATION_OFFLINE") == "1")
    parser.add_argument("--check", action="store_true", help="Require an existing environment; never create or modify it")
    args = parser.parse_args()
    if sys.implementation.name != "cpython" or not (3, 11) <= sys.version_info[:2] <= (3, 14):
        parser.error("validation requires CPython 3.11 through 3.14")
    expected = identity()
    key = hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest()[:24]
    cache = args.cache_dir.expanduser().resolve()
    environment = cache / "envs" / key
    if verify(environment, expected):
        print(environment)
        return 0
    if args.check:
        raise SystemExit("Validation environment is missing or stale; run scripts/prepare-validation-env.py during preparation.")
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / ".prepare.lock").open("a") as mutex:
        fcntl.flock(mutex, fcntl.LOCK_EX)
        if verify(environment, expected):
            print(environment)
            return 0
        if environment.exists():
            raise SystemExit(f"Incomplete validation environment: {environment}. Remove it and rerun preparation.")
        wheelhouse = (args.wheelhouse or cache / "wheels").expanduser().resolve()
        if args.offline and not wheelhouse.is_dir():
            raise SystemExit(f"Offline wheelhouse does not exist: {wheelhouse}")
        wheelhouse.mkdir(parents=True, exist_ok=True)
        print(f"Preparing Python validation environment: {environment}", file=sys.stderr)
        try:
            # ensurepip uses Python's bundled pip; no system pip/package mutation.
            venv.EnvBuilder(with_pip=True).create(environment)
            if not args.offline:
                pip(environment, "download", "--index-url", "https://pypi.org/simple",
                    "--only-binary=:all:", "--require-hashes", "--dest", str(wheelhouse), "-r", str(LOCK))
            pip(environment, "install", "--no-index", "--find-links", str(wheelhouse),
                "--only-binary=:all:", "--require-hashes", "--no-compile", "-r", str(LOCK))
            (environment / "devario-validation.json").write_text(json.dumps(expected, sort_keys=True) + "\n")
            if not verify(environment, expected):
                raise RuntimeError("Validation environment failed its import/version checks")
        except BaseException:
            shutil.rmtree(environment)
            raise
    print(environment)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        raise SystemExit(f"Validation environment preparation failed: {error}") from error
