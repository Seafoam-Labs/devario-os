#!/usr/bin/env python3
"""Stage the exact signed devario-core closure, preserving metadata bytes."""

import argparse
import concurrent.futures
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request


PROJECT = Path(__file__).resolve().parents[1]


def download(url, path):
    temporary = path.with_name(path.name + ".part")
    try:
        with urllib.request.urlopen(url, timeout=120) as response, temporary.open("wb") as output:
            if not response.url.startswith("https://"):
                raise ValueError("repository download redirected outside HTTPS")
            shutil.copyfileobj(response, output, 1024 * 1024)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def records(path):
    result = {}
    with tarfile.open(path) as archive:
        for member in archive:
            if not member.name.endswith("/desc"):
                continue
            if not member.isfile() or member.size > 1024 * 1024:
                raise ValueError("unsafe repository description")
            fields, key = {}, None
            for line in archive.extractfile(member).read().decode().splitlines():
                if line.startswith("%") and line.endswith("%"):
                    key = line.strip("%")
                    if key in fields:
                        raise ValueError("duplicate repository field")
                    fields[key] = []
                elif line and key:
                    fields[key].append(line)
            row = tuple(fields[k][0] for k in ("NAME", "VERSION", "ARCH", "FILENAME", "CSIZE", "SHA256SUM"))
            name, _, arch, filename, size, digest = row
            if name in result or arch not in ("any", "x86_64") or not re.fullmatch(r"[A-Za-z0-9@._+:-]+\.pkg\.tar\.zst", filename):
                raise ValueError("unsafe or duplicate repository package")
            if not size.isdecimal() or not re.fullmatch("[0-9a-f]{64}", digest):
                raise ValueError("missing package size or SHA-256")
            result[name] = row
    if not result:
        raise ValueError("empty repository database")
    return result


def matches(path, size, digest):
    if not path.is_file() or path.is_symlink() or path.stat().st_size != int(size):
        return False
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest() == digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="https://mirrors.seafoam-labs.org/devario-core/x86_64")
    parser.add_argument("--output", type=Path, default=PROJECT / "repo/core")
    parser.add_argument("--cache", type=Path, default=PROJECT / "work/repository-downloads")
    parser.add_argument("--keyring", type=Path, default=PROJECT / "packages/devario-keyring")
    parser.add_argument("--jobs", type=int, default=6)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 16:
        parser.error("--jobs must be between 1 and 16")
    library = PROJECT / "scripts/lib/repository.sh"
    def trust(command, *values):
        subprocess.run(["bash", "-euc", 'source "$1"; devario_validate_keyring_bundle "$2" devario-core production; ' + command,
                        "stage-core", str(library), str(args.keyring.resolve()), *map(str, values)], check=True,
                       stdout=subprocess.DEVNULL)
    trust('devario_validate_https_url "$3"', args.url)
    output, cache = args.output.absolute(), args.cache.resolve()
    if output.exists() or output.is_symlink():
        parser.error("output already exists; choose a fresh output directory")
    cache.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".core-staging-", dir=output.parent) as temporary:
        stage = Path(temporary) / "core"
        stage.mkdir()
        for kind in ("db", "files"):
            # The local closure naming contract is .tar.zst. Preserve the exact
            # downloaded bytes even when the upstream archive uses gzip.
            canonical = stage / f"devario-core.{kind}.tar.zst"
            download(f"{args.url.rstrip('/')}/devario-core.{kind}", canonical)
            signature = canonical.with_name(canonical.name + ".sig")
            download(f"{args.url.rstrip('/')}/devario-core.{kind}.sig", signature)
            trust('devario_gpgv_active_signature "$3" "$4"', signature, canonical)
            (stage / f"devario-core.{kind}").symlink_to(canonical.name)
            (stage / f"devario-core.{kind}.sig").symlink_to(signature.name)
        packages = records(stage / "devario-core.db")
        if packages != records(stage / "devario-core.files"):
            raise ValueError("database/files snapshots differ; rerun after publication settles")
        total = sum(int(row[4]) for row in packages.values())
        print(f"Verified metadata: {len(packages)} packages, {total / 1e9:.2f} GB", flush=True)
        def fetch(row):
            name, _, _, filename, size, digest = row
            artifact = cache / filename
            signature = artifact.with_name(filename + ".sig")
            url = args.url.rstrip('/') + '/' + urllib.parse.quote(filename, safe='')
            if not matches(artifact, size, digest):
                download(url, artifact)
                signature.unlink(missing_ok=True)
            if not matches(artifact, size, digest):
                raise ValueError(f"package checksum/size mismatch: {filename}")
            if not signature.is_file():
                download(url + '.sig', signature)
            trust('devario_gpgv_active_signature "$3" "$4"', signature, artifact)
            for path in (artifact, signature):
                shutil.copyfile(path, stage / path.name)
            return name
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = [pool.submit(fetch, row) for row in packages.values()]
            for count, future in enumerate(concurrent.futures.as_completed(futures), 1):
                future.result()
                if count % 50 == 0 or count == len(futures):
                    print(f"Verified and staged {count}/{len(futures)} packages", flush=True)
        print("Checking package identities against both signed databases...", flush=True)
        trust('devario_verify_repository "$3" devario-core "$2" production', stage)
        stage.rename(output)
    print(f"Signed repository staged at {output}", flush=True)
    audit = output.parent / (output.name + "-dependency-audit.json")
    dependencies = subprocess.run(["python3", str(PROJECT / "scripts/audit-iso-repositories.py"),
                                   "--database", "devario-core", str(output / "devario-core.db"),
                                   "--packages", str(PROJECT / "iso/packages.x86_64"), "--output", str(audit)])
    paths = subprocess.run(["python3", str(PROJECT / "scripts/audit-iso-package-paths.py"),
                            "--files", str(output / "devario-core.files"), "--dependency-audit", str(audit),
                            "--output", str(output.parent / (output.name + "-path-audit.json"))])
    return bool(dependencies.returncode or paths.returncode)


if __name__ == "__main__":
    raise SystemExit(main())
