#!/usr/bin/env python3
"""Audit dependency-name coverage in signature-verified repository databases.

Shelly's native resolver validates version constraints during installation.
This metadata preflight does not implement a second package version resolver.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tarfile

SCOPE = ("Dependency-name coverage only; Shelly validates version constraints, "
         "provider compatibility, conflicts and installability during installation")


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


def dependency_name(requirement):
    return re.split(r"[<>=]", requirement, maxsplit=1)[0]


def resolve(requested, packages):
    # Shelly orders virtual-provider candidates by name within a repository;
    # tar entry order is not a provider preference. Keep repository priority
    # (and same-name copies) stable while making each repository deterministic.
    repository_order = {name: index for index, name in
                        enumerate(dict.fromkeys(p.get("repository", "") for p in packages))}
    packages = sorted(packages, key=lambda p: (repository_order[p.get("repository", "")], p["name"]))
    selected = {}
    missing = {}
    requested_names = {dependency_name(name) for name in requested}
    pending = [(name, "ISO package list") for name in requested]
    while pending:
        requirement, parent = pending.pop()
        name = dependency_name(requirement)
        candidates = []
        for package in packages:
            if name == package["name"]:
                candidates.append(package)
                continue
            for provide in package["provides"]:
                if name == dependency_name(provide):
                    candidates.append(package)
                    break
        if not candidates:
            missing.setdefault(requirement, set()).add(parent)
            continue
        # Prefer explicit ISO targets over another virtual provider, even when
        # their entries have not yet been visited (e.g. devario-dracut/initramfs).
        package = next((p for p in candidates if p["name"] in selected), None)
        if package is None:
            package = next((p for p in candidates if p["name"] in requested_names), None)
        if package is None:
            # Match Shelly's preference for a literal package name before a
            # virtual provider. Archive order must not pin zlib-ng-compat's
            # unversioned "zlib" provision instead of the real zlib package.
            package = next((p for p in candidates if p["name"] == name), candidates[0])
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
                  scope=SCOPE)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"Selected {len(selected)} packages; {len(missing)} unresolved requirements. Report: {args.output}")
    for requirement, parents in missing.items():
        print(f"Missing {requirement} (required by {', '.join(parents)})")
    raise SystemExit(bool(missing))


if __name__ == "__main__":
    main()
