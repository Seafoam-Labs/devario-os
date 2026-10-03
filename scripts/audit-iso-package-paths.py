#!/usr/bin/env python3
"""Check selected packages for hook and key-bundle paths from the old layout."""
import argparse
import json
from pathlib import Path
import tarfile


def audit(files_database, selected):
    issues = []
    with tarfile.open(files_database) as archive:
        members = {member.name: member for member in archive}
        for name, member in members.items():
            if not name.endswith("/desc"):
                continue
            lines = archive.extractfile(member).read().decode().splitlines()
            package = lines[lines.index("%NAME%") + 1]
            if package not in selected:
                continue
            listing = members.get(name[:-4] + "files")
            if not listing:
                raise ValueError(f"missing file inventory: {package}")
            paths = archive.extractfile(listing).read().decode().splitlines()
            legacy = [p for p in paths if not p.endswith("/") and p.startswith((
                "usr/share/libalpm/hooks/", "usr/share/libalpm/scripts/", "usr/share/pacman/keyrings/"))]
            if legacy:
                issues.append({"package": package, "paths": sorted(legacy)})
    return sorted(issues, key=lambda record: record["package"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--files", required=True, type=Path)
    parser.add_argument("--dependency-audit", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    selected = {p["name"] for p in json.loads(args.dependency_audit.read_text())["selected"]}
    issues = audit(args.files, selected)
    args.output.write_text(json.dumps({"complete": not issues, "packages": issues}, indent=2) + "\n")
    print(f"{len(issues)} selected packages still use old hook/key-bundle paths. Report: {args.output}")
    return bool(issues)


if __name__ == "__main__":
    raise SystemExit(main())
