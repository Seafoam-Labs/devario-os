#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bundle the 580 alternative from the already authenticated ISO repository."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import types

PROJECT = Path(__file__).resolve().parents[1]
HELPER = PROJECT / "iso/airootfs/usr/lib/devario/configure-target-nvidia"
nvidia = types.ModuleType("nvidia")
exec(compile(HELPER.read_text(), str(HELPER), "exec"), nvidia.__dict__)
spec = importlib.util.spec_from_file_location("audit", PROJECT / "scripts/audit-iso-repositories.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def contents(archive, member):
    return subprocess.check_output(["bsdtar", "-xOf", str(archive), member], text=True)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def stage(repository, profile):
    # build-iso.sh verifies this entire repository before invoking us. Keep
    # detached signatures and hashes with the payload for target installation.
    archives = {}
    records = {}
    version = None
    for name in nvidia.LEGACY_PACKAGES:
        matches = list(repository.glob(f"{name}-[0-9]*.pkg.tar.zst"))
        if len(matches) != 1:
            raise ValueError(f"Expected exactly one signed {name} archive; restage ISO repositories")
        archive = matches[0]
        metadata = dict(line.split(" = ", 1) for line in contents(archive, ".PKGINFO").splitlines()
                        if " = " in line)
        upstream = metadata["pkgver"].split(":")[-1].rsplit("-", 1)[0]
        if metadata["pkgname"] != name or not upstream.startswith("580."):
            raise ValueError(f"Invalid NVIDIA 580 package: {archive}")
        if version is not None and upstream != version:
            raise ValueError("NVIDIA 580 DKMS and utilities versions differ")
        version = upstream
        signature = Path(str(archive) + ".sig")
        records[name] = dict(filename=archive.name, sha256=digest(archive), signatureSha256=digest(signature))
        archives[name] = archive

    support = nvidia.proprietary_support(contents(archives["nvidia-580xx-utils"],
                                                "usr/share/doc/nvidia/html/supportedchips.html"), version,
                                        json.loads(contents(archives["nvidia-580xx-utils"],
                                                            "usr/share/doc/nvidia/supported-gpus.json")))
    dkms_files = subprocess.check_output(["bsdtar", "-tf", str(archives["nvidia-580xx-dkms"])], text=True).splitlines()
    utils_files = subprocess.check_output(["bsdtar", "-tf", str(archives["nvidia-580xx-utils"])], text=True).splitlines()
    if f"usr/src/nvidia-{version}/dkms.conf" not in dkms_files:
        raise ValueError("NVIDIA 580 archive has no DKMS sources")
    for firmware in nvidia.FIRMWARE[:2]:
        path = f"usr/lib/firmware/nvidia/{version}/{firmware}"
        if not any(path + suffix in utils_files for suffix in ("", ".zst", ".xz")):
            raise ValueError(f"NVIDIA 580 archive is missing {firmware}")

    packages = audit.records(repository / "devario-core.db", "devario-core")
    requested = [line.strip() for line in (profile / "packages.x86_64").read_text().splitlines()
                 if line.strip() and not line.lstrip().startswith("#")]
    live, missing = audit.resolve(requested, packages)
    alternative, alternative_missing = audit.resolve(
        [name for name in requested if name not in nvidia.OPEN_PACKAGES] + list(nvidia.LEGACY_PACKAGES),
        [p for p in packages if p["name"] not in nvidia.OPEN_PACKAGES])
    extra = set(alternative) - set(live) - set(nvidia.LEGACY_PACKAGES)
    if missing or alternative_missing or extra:
        raise ValueError(f"NVIDIA 580 offline dependencies are incomplete: {missing}, {alternative_missing}, "
                         f"add these shared dependencies to packages.x86_64: {sorted(extra)}")

    destination = profile / "airootfs" / nvidia.LEGACY_PAYLOAD.relative_to("/")
    destination.mkdir(parents=True, exist_ok=True)
    for archive in archives.values():
        shutil.copyfile(archive, destination / archive.name)
        shutil.copyfile(str(archive) + ".sig", destination / (archive.name + ".sig"))
    support["packages"] = records
    (destination / "manifest.json").write_text(json.dumps(support, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("profile", type=Path)
    args = parser.parse_args()
    stage(args.repository, args.profile)
