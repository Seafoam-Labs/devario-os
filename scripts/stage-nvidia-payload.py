#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Stage NVIDIA support metadata and the 580 alternative from the verified repository."""
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
spec = importlib.util.spec_from_file_location("gpu_support", PROJECT / "scripts/update-nvidia-supported-gpus.py")
gpu_support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gpu_support)


def contents(archive, member):
    return subprocess.check_output(["bsdtar", "-xOf", str(archive), member], text=True)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def open_support(repository, packages):
    """Bind the installer's table to the exact open driver selected for the ISO."""
    archives = {}
    version = None
    for name in nvidia.OPEN_PACKAGES:
        matches = [package for package in packages if package["name"] == name]
        if len(matches) != 1:
            raise ValueError(f"Expected exactly one signed {name} package; restage ISO repositories")
        package = matches[0]
        filename = package["filename"]
        if Path(filename).name != filename:
            raise ValueError(f"Invalid NVIDIA archive filename: {filename}")
        archive = repository / filename
        # Signature verification is performed by build-iso.sh before staging.
        if not Path(str(archive) + ".sig").is_file():
            raise ValueError(f"Missing NVIDIA package signature: {archive}")
        metadata = dict(line.split(" = ", 1) for line in contents(archive, ".PKGINFO").splitlines()
                        if " = " in line)
        if metadata["pkgname"] != name or metadata["pkgver"] != package["version"]:
            raise ValueError(f"NVIDIA package metadata differs from repository: {archive}")
        upstream = metadata["pkgver"].split(":")[-1].rsplit("-", 1)[0]
        if version is not None and upstream != version:
            raise ValueError("NVIDIA open DKMS and utilities versions differ")
        version = upstream
        archives[name] = archive
    readme = subprocess.check_output(["bsdtar", "-xOf", str(archives["nvidia-open-dkms"]),
                                      f"usr/src/nvidia-{version}/README.md"])
    return gpu_support.extract(readme, version)


def stage(repository, profile):
    # build-iso.sh verifies this entire repository before invoking us. Keep
    # detached signatures and hashes with the payload for target installation.
    packages = audit.records(repository / "devario-core.db", "devario-core")
    current_support = open_support(repository, packages)
    archives = {}
    records = {}
    version = None
    for name in nvidia.LEGACY_PACKAGES:
        matches = [package for package in packages if package["name"] == name]
        if len(matches) != 1:
            raise ValueError(f"Expected exactly one signed {name} package; restage ISO repositories")
        package = matches[0]
        filename = package["filename"]
        if Path(filename).name != filename:
            raise ValueError(f"Invalid NVIDIA archive filename: {filename}")
        archive = repository / filename
        metadata = dict(line.split(" = ", 1) for line in contents(archive, ".PKGINFO").splitlines()
                        if " = " in line)
        if metadata["pkgname"] != name or metadata["pkgver"] != package["version"]:
            raise ValueError(f"NVIDIA package metadata differs from repository: {archive}")
        upstream = metadata["pkgver"].split(":")[-1].rsplit("-", 1)[0]
        if metadata["pkgname"] != name or not upstream.startswith("580."):
            raise ValueError(f"Invalid NVIDIA 580 package: {archive}")
        if version is not None and upstream != version:
            raise ValueError("NVIDIA 580 driver, OpenCL and multilib versions differ")
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
    for name, required in {
        "opencl-nvidia-580xx": (f"usr/lib/libnvidia-opencl.so.{version}", "etc/OpenCL/vendors/nvidia.icd"),
        "lib32-nvidia-580xx-utils": (f"usr/lib32/libGLX_nvidia.so.{version}",
                                    f"usr/lib32/libEGL_nvidia.so.{version}"),
        "lib32-opencl-nvidia-580xx": (f"usr/lib32/libnvidia-opencl.so.{version}",),
    }.items():
        files = subprocess.check_output(["bsdtar", "-tf", str(archives[name])], text=True).splitlines()
        if not set(required).issubset(files):
            raise ValueError(f"NVIDIA 580 archive {name} is missing graphics/OpenCL libraries or ICD")

    requested = [line.strip() for line in (profile / "packages.x86_64").read_text().splitlines()
                 if line.strip() and not line.lstrip().startswith("#")]
    live, missing = audit.resolve(requested, packages)
    alternative, alternative_missing = audit.resolve(
        [name for name in requested if name not in nvidia.CURRENT_PACKAGES] + list(nvidia.LEGACY_PACKAGES),
        [p for p in packages if p["name"] not in (*nvidia.CURRENT_PACKAGES, "nvidia-580xx-open-dkms")])
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
    support_path = profile / "airootfs" / nvidia.SUPPORT.relative_to("/")
    support_path.write_text(json.dumps(current_support, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("profile", type=Path)
    args = parser.parse_args()
    stage(args.repository, args.profile)
