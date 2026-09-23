#!/usr/bin/env python3
"""Audit an ISO package closure against downloaded, signature-verified databases."""
import argparse
import hashlib
import json
from pathlib import Path
import re
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


def satisfies(requirement, name, version):
    match = re.fullmatch(r"([^<>=]+)(>=|<=|=|>|<)?(.*)", requirement)
    if not match or match[1] != name:
        return False
    if not match[2]:
        return True
    if not version:
        return False
    comparison = int(subprocess.check_output(["vercmp", version, match[3]], text=True).strip())
    return {"=": comparison == 0, ">=": comparison >= 0, "<=": comparison <= 0,
            ">": comparison > 0, "<": comparison < 0}[match[2]]


def resolve(requested, packages):
    selected = {}
    missing = {}
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
        # Caller supplies repository precedence. Prefer an already selected
        # provider to keep recursive dependencies consistent.
        package = next((p for p in candidates if p["name"] in selected), candidates[0])
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
    raise SystemExit(bool(missing))


if __name__ == "__main__":
    main()
