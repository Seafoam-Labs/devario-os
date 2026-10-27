#!/usr/bin/env python3
"""Check kernel/header compatibility in a signature-verified ISO repository.

Repository verification must run first. Versions and archive filenames come
from its database; this check has no preferred kernel release or source recipe.
"""
import argparse
import importlib.util
from pathlib import Path
import re
import subprocess

spec = importlib.util.spec_from_file_location(
    "repository_audit", Path(__file__).with_name("audit-iso-repositories.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def contents(archive, member):
    return subprocess.check_output(["bsdtar", "-xOf", str(archive), member], text=True).strip()


def validate(repository):
    records = audit.records(repository / "devario-core.db", "devario-core")
    packages = {}
    for name in ("linux-devario", "linux-devario-headers"):
        matches = [record for record in records if record["name"] == name]
        if len(matches) != 1:
            raise ValueError(f"Expected exactly one {name} entry in the repository")
        record = matches[0]
        filename = record["filename"]
        if Path(filename).name != filename or filename in ("", ".", ".."):
            raise ValueError(f"Invalid kernel archive filename: {filename}")
        archive = repository / filename
        metadata = dict(line.split(" = ", 1) for line in contents(archive, ".PKGINFO").splitlines()
                        if " = " in line)
        if metadata.get("pkgname") != name or metadata.get("pkgver") != record["version"]:
            raise ValueError(f"Kernel package metadata differs from repository: {name}")
        if metadata.get("arch") != "x86_64":
            raise ValueError(f"Expected x86_64 kernel package: {name}")
        packages[name] = (record["version"], archive)
    version, kernel = packages["linux-devario"]
    headers_version, headers = packages["linux-devario-headers"]
    if version != headers_version:
        raise ValueError("Repository kernel and headers versions differ")

    paths = set(subprocess.check_output(["bsdtar", "-tf", str(kernel)], text=True).splitlines())
    images = [path for path in paths if re.fullmatch(r"usr/lib/modules/[A-Za-z0-9][A-Za-z0-9._+-]*/vmlinuz", path)]
    if len(images) != 1:
        raise ValueError("Kernel package must contain exactly one module tree with vmlinuz")
    tree = images[0].rsplit("/", 1)[0]
    release = tree.rsplit("/", 1)[1]
    if tree + "/devario-kernel" in paths:
        lines = contents(kernel, tree + "/devario-kernel").splitlines()
        expected = {f"version={release}", "image=vmlinuz", "id=linux-devario"}
        if len(lines) != len(expected) or set(lines) != expected:
            raise ValueError("Kernel boot metadata does not match its module tree")
    elif contents(kernel, tree + "/pkgbase") != "linux-devario":
        raise ValueError("Kernel pkgbase must identify linux-devario")
    if contents(headers, tree + "/build/include/config/kernel.release") != release:
        raise ValueError("Headers kernel release does not match the kernel module tree")
    config = dict(line.split("=", 1) for line in contents(headers, tree + "/build/.config").splitlines()
                  if line.startswith("CONFIG_") and "=" in line)
    for name, allowed in {"CONFIG_BLK_DEV_INITRD": {"y"}, "CONFIG_EFI_STUB": {"y"},
                          "CONFIG_SQUASHFS": {"y", "m"}, "CONFIG_OVERLAY_FS": {"y", "m"},
                          "CONFIG_BLK_DEV_LOOP": {"y", "m"}}.items():
        if config.get(name) not in allowed:
            raise ValueError(f"Repository kernel lacks live boot support: {name}")
    return version, release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path, help="Previously verified devario-core snapshot directory")
    args = parser.parse_args()
    try:
        version, release = validate(args.repository)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Kernel validation error: {error}\n")
    print(f"Repository kernel and headers validated: {version} ({release})")


if __name__ == "__main__":
    main()
