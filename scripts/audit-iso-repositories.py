#!/usr/bin/env python3
"""Audit an ISO package closure against downloaded, signature-verified databases."""
import argparse
import ctypes
import ctypes.util
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile


def records(path, repository):
    result = []
    with tarfile.open(path) as archive:
        for member in archive:
            if not member.name.endswith("/desc"):
                continue
            fields = {}
            for block in archive.extractfile(member).read().decode().strip().split("\n\n"):
                lines = block.splitlines()
                fields[lines[0].strip("%")] = lines[1:]
            result.append(dict(name=fields["NAME"][0], version=fields["VERSION"][0],
                               repository=repository, depends=fields.get("DEPENDS", []),
                               provides=fields.get("PROVIDES", []), filename=fields["FILENAME"][0]))
    return result


@lru_cache(maxsize=1)
def alpm_comparator():
    library = ctypes.util.find_library("alpm")
    if not library:
        raise RuntimeError("Package version comparison requires vercmp or libalpm (Ubuntu: libalpm13t64)")
    compare = ctypes.CDLL(library).alpm_pkg_vercmp
    compare.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    compare.restype = ctypes.c_int
    return compare


def compare_versions(left, right):
    if shutil.which("vercmp"):
        return int(subprocess.check_output(["vercmp", left, right], text=True).strip())
    return alpm_comparator()(left.encode(), right.encode())


def satisfies(requirement, name, version):
    match = re.fullmatch(r"([^<>=]+)(>=|<=|=|>|<)?(.*)", requirement)
    if not match or match[1] != name:
        return False
    if not match[2]:
        return True
    if not version:
        return False
    comparison = compare_versions(version, match[3])
    return {"=": comparison == 0, ">=": comparison >= 0, "<=": comparison <= 0,
            ">": comparison > 0, "<": comparison < 0}[match[2]]


def resolve(requested, packages):
    selected = {}
    missing = {}
    requested_names = {re.split(r"[<>=]", name, maxsplit=1)[0] for name in requested}
    pending = [(name, "ISO package list") for name in requested]
    while pending:
        requirement, parent = pending.pop()
        candidates = []
        for package in packages:
            if satisfies(requirement, package["name"], package["version"]):
                candidates.append(package)
                continue
            for provide in package["provides"]:
                name, _, version = provide.partition("=")
                if satisfies(requirement, name, version):
                    candidates.append(package)
                    break
        if not candidates:
            missing.setdefault(requirement, set()).add(parent)
            continue
        # Prefer explicit ISO targets over another virtual provider, even when
        # their entries have not yet been visited (e.g. devario-dracut/initramfs).
        package = next((p for p in candidates if p["name"] in selected), None)
        if package is None:
            package = next((p for p in candidates if p["name"] in requested_names), candidates[0])
        if package["name"] in selected:
            continue
        selected[package["name"]] = package
        pending.extend((dep, package["name"]) for dep in package["depends"])
    return selected, {name: sorted(parents) for name, parents in sorted(missing.items())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", action="append", nargs=2, metavar=("REPOSITORY", "PATH"), required=True)
    parser.add_argument("--packages", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    packages, inputs = [], []
    for repository, filename in args.database:
        path = Path(filename)
        packages.extend(records(path, repository))
        inputs.append(dict(repository=repository, sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    requested = [line.strip() for line in args.packages.read_text().splitlines()
                 if line.strip() and not line.lstrip().startswith("#")]
    selected, missing = resolve(requested, packages)
    result = dict(schemaVersion=1, databases=inputs, requested=requested,
                  selected=[selected[n] for n in sorted(selected)], missing=missing,
                  complete=not missing,
                  scope="Database dependency audit; package signatures, conflicts and installation still require verification")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"Selected {len(selected)} packages; {len(missing)} unresolved requirements. Report: {args.output}")
    for requirement, parents in missing.items():
        print(f"Missing {requirement} (required by {', '.join(parents)})")
    raise SystemExit(bool(missing))


if __name__ == "__main__":
    main()
