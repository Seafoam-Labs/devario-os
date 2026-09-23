#!/usr/bin/env python3
"""Create or verify the immutable input closure used by nspawn builds."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import tarfile
import re
from urllib.parse import unquote, urlsplit

from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError, ValidationError


def reject_duplicate_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json_bytes(value: bytes) -> object:
    return json.loads(value, object_pairs_hook=reject_duplicate_pairs)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_credential_free_https_url(value: str, *, reject_latest: bool = False) -> None:
    if not re.fullmatch(
        r"https://(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*"
        r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
        r"(?::[0-9]{1,5})?(?:/[A-Za-z0-9._~!$&'()*+,;=:/-]*)?",
        value,
    ):
        raise ValueError("URL must be canonical credential-free HTTPS without query or fragment")
    parsed = urlsplit(value)
    if parsed.username is not None or parsed.password is not None or parsed.query or parsed.fragment:
        raise ValueError("URL must not contain credentials, a query string, or a fragment")
    try:
        if parsed.port is not None and not 1 <= parsed.port <= 65535:
            raise ValueError("URL port is out of range")
    except ValueError as error:
        raise ValueError("URL port is invalid") from error
    decoded_path = unquote(parsed.path)
    if "//" in decoded_path or any(segment in (".", "..") for segment in decoded_path.split("/")):
        raise ValueError("URL path is non-canonical or contains traversal")
    if reject_latest and any(segment.lower() == "latest" for segment in decoded_path.split("/")):
        raise ValueError("bootstrap URL must identify an immutable version, not latest")


def validate_release_version(value: str) -> None:
    if len(value) > 64 or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value):
        raise ValueError(
            "release version must match [A-Za-z0-9][A-Za-z0-9._-]{0,63}"
        )


def verify_signature(signature: Path, artifact: Path, keyring: Path, active: str | None = None) -> None:
    result = subprocess.run(
        ["gpgv", "--status-fd", "1", "--keyring", str(keyring), str(signature), str(artifact)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if result.returncode:
        raise ValueError(f"signature verification failed: {artifact.name}")
    valid = [line.split() for line in result.stdout.splitlines() if line.startswith("[GNUPG:] VALIDSIG ")]
    if len(valid) != 1:
        raise ValueError(f"expected exactly one valid signature: {artifact.name}")
    if active is not None and (len(valid[0]) < 12 or valid[0][-1] != active):
        raise ValueError(f"artifact was not signed by active core signer: {artifact.name}")


def arch_database_packages(path: Path) -> set[tuple[str, str, str]]:
    packages: set[tuple[str, str, str]] = set()
    with tarfile.open(path, mode="r:*") as archive:
        for member in archive.getmembers():
            if not member.isfile() or not member.name.endswith("/desc"):
                continue
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError(f"unreadable Arch database record: {member.name}")
            lines = stream.read().decode("utf-8").splitlines()
            fields: dict[str, str] = {}
            index = 0
            while index < len(lines):
                if lines[index].startswith("%") and lines[index].endswith("%") and index + 1 < len(lines):
                    fields[lines[index][1:-1]] = lines[index + 1]
                    index += 2
                else:
                    index += 1
            if not all(fields.get(key) for key in ("NAME", "VERSION", "ARCH")):
                raise ValueError(f"incomplete Arch database record: {member.name}")
            packages.add((fields["NAME"], fields["VERSION"], fields["ARCH"]))
    if not packages:
        raise ValueError(f"Arch database contains no package records: {path}")
    return packages


def validate_dependency_closure(
    dependency_closure: object, database_paths: list[Path]
) -> list[dict[str, str]]:
    if not isinstance(dependency_closure, list) or not dependency_closure:
        raise ValueError("dependency closure must be a nonempty JSON array")
    normalized: list[dict[str, str]] = []
    for item in dependency_closure:
        if not isinstance(item, dict) or set(item) != {"name", "version", "architecture"}:
            raise ValueError("dependency closure records require only name/version/architecture")
        if not isinstance(item["name"], str) or not item["name"] \
                or not isinstance(item["version"], str) or not item["version"] \
                or item["architecture"] not in ("any", "x86_64"):
            raise ValueError("dependency closure contains an invalid package identity")
        normalized.append(item)
    if normalized != sorted(normalized, key=lambda item: item["name"]):
        raise ValueError("dependency closure must be sorted by package name")
    names = [item["name"] for item in normalized]
    if len(names) != len(set(names)):
        raise ValueError("dependency closure contains duplicate package names")
    available_packages: set[tuple[str, str, str]] = set()
    for database_path in database_paths:
        available_packages.update(arch_database_packages(database_path))
    for item in normalized:
        identity = (item["name"], item["version"], item["architecture"])
        if identity not in available_packages:
            raise ValueError(
                "dependency closure identity is absent from locked core/extra databases: "
                + "|".join(identity)
            )
    return normalized


def clean_git_identity(path: Path, boundary: Path) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="devario-boundary.") as temporary:
        archive = Path(temporary) / "source.tar"
        report = Path(temporary) / "report.json"
        subprocess.run(
            [
                str(boundary),
                "--repository",
                str(path),
                "--archive",
                str(archive),
                "--report",
                str(report),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        return load_json_bytes(report.read_bytes())


def closure(path: Path, label: str, symlinks: bool = False) -> dict[str, object]:
    root = path.resolve(strict=True)
    if not root.is_dir():
        raise ValueError(f"{label} is not a directory: {path}")
    entries: list[dict[str, object]] = []
    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames.sort()
        filenames.sort()
        for name in list(dirnames):
            candidate = Path(directory) / name
            if candidate.is_symlink():
                dirnames.remove(name)
                filenames.append(name)
        for name in sorted(filenames):
            candidate = Path(directory) / name
            relative = candidate.relative_to(root).as_posix()
            mode = candidate.lstat().st_mode
            if stat.S_ISLNK(mode):
                if not symlinks:
                    raise ValueError(f"{label} contains a symlink: {relative}")
                target = os.readlink(candidate)
                if "/" in target or target in (".", "..") or not (root / target).is_file():
                    raise ValueError(f"{label} contains an unsafe symlink: {relative}")
                entries.append({"path": relative, "mode": "120000", "target": target})
            elif stat.S_ISREG(mode):
                entries.append(
                    {
                        "path": relative,
                        "mode": "100755" if mode & 0o111 else "100644",
                        "size": candidate.stat().st_size,
                        "sha256": sha256(candidate),
                    }
                )
            else:
                raise ValueError(f"{label} contains a special file: {relative}")
    if not entries:
        raise ValueError(f"{label} has an empty input closure")
    return {"name": label, "files": entries}


def edition_id(path: Path) -> str:
    values: dict[str, str] = {}
    for line in (path / "edition.conf").read_text(encoding="ascii").splitlines():
        if "=" not in line:
            raise ValueError("edition.conf has invalid syntax")
        key, value = line.split("=", 1)
        if key in values:
            raise ValueError(f"duplicate edition.conf key: {key}")
        values[key] = value
    value = values.get("id", "")
    if not value:
        raise ValueError("edition.conf has no id")
    return value


def build(args: argparse.Namespace) -> dict[str, object]:
    script_dir = Path(__file__).resolve().parent
    boundary = script_dir / "verify-repository-boundary.sh"
    core = args.core.resolve(strict=True)
    edition = args.edition.resolve(strict=True)
    core_identity = clean_git_identity(core, boundary)
    internal_edition = edition == core / "editions" / edition.name
    if edition == core / "editions" / "community":
        internal_edition = True
    if internal_edition:
        edition_identity: dict[str, object] = {
            "commit": core_identity["commit"],
            "tree": core_identity["tree"],
            "path": edition.relative_to(core).as_posix(),
        }
    else:
        edition_identity = clean_git_identity(edition, boundary)
        lock_lines = (edition / "base.lock").read_text(encoding="ascii").splitlines()
        if lock_lines != [f"devario_os_commit={core_identity['commit']}"]:
            raise ValueError("external edition base.lock does not pin the exact core commit")

    source_manifest = core / "release/source-manifest.json"
    if not source_manifest.is_file() or source_manifest.is_symlink():
        raise ValueError("release/source-manifest.json is missing or unsafe")
    locked_files: dict[str, Path] = {
        "bootstrap archive": args.bootstrap_archive,
        "bootstrap signature": args.bootstrap_signature,
        "Shelly bootstrap package": args.shelly_bootstrap,
        "Shelly bootstrap signature": args.shelly_bootstrap_signature,
        "controlled builder manifest": args.builder_manifest,
        "controlled builder manifest signature": args.builder_manifest_signature,
        "dependency closure": args.dependency_closure,
    }
    for repository in ("devario-core", "seafoam-labs"):
        locked_files[f"Repository {repository} database"] = args.repository_snapshot_dir / f"{repository}.db"
        locked_files[f"Repository {repository} database signature"] = args.repository_snapshot_dir / f"{repository}.db.sig"
    resolved_files: dict[str, Path] = {}
    for label, value in locked_files.items():
        path = value.resolve(strict=True)
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"{label} is missing or unsafe")
        resolved_files[label] = path
    bootstrap = resolved_files["bootstrap archive"]
    bootstrap_keyring = args.bootstrap_keyring.resolve(strict=True)
    if not bootstrap_keyring.is_file() or bootstrap_keyring.is_symlink():
        raise ValueError("Bootstrap release keyring is missing or unsafe")
    validate_credential_free_https_url(args.bootstrap_url, reject_latest=True)
    if not re.fullmatch(
        r"https://[a-z0-9.-]+(?::[0-9]{1,5})?/snapshots/[A-Za-z0-9._-]+/",
        args.repository_snapshot_url,
    ):
        raise ValueError("Repository snapshot URL must select an immutable /snapshots/ identifier")
    if args.source_date_epoch != int(core_identity["sourceDateEpoch"]):
        raise ValueError("SOURCE_DATE_EPOCH must equal the verified core commit timestamp")

    builder_manifest = load_json_bytes(resolved_files["controlled builder manifest"].read_bytes())
    builder_manifest_bytes = canonical(builder_manifest)
    if resolved_files["controlled builder manifest"].read_bytes() != builder_manifest_bytes:
        raise ValueError("controlled builder manifest is not canonical JSON")
    builder_schema = load_json_bytes((script_dir / "schemas/controlled-builder.schema.json").read_bytes())
    Draft202012Validator(builder_schema).validate(builder_manifest)
    builder_keyring = (args.builder_keyring or args.core_keyring).resolve(strict=True)
    if args.builder_repository == "devario-core":
        builder_public = builder_keyring / "devario.gpg"
    else:
        builder_public = builder_keyring / "devario-managed.gpg"
    builder_active = (builder_keyring / "active-signer").read_text(encoding="ascii").strip()
    verify_signature(
        resolved_files["controlled builder manifest signature"],
        resolved_files["controlled builder manifest"],
        builder_public,
        builder_active,
    )
    dependency_closure = load_json_bytes(resolved_files["dependency closure"].read_bytes())
    dependency_bytes = canonical(dependency_closure)
    if resolved_files["dependency closure"].read_bytes() != dependency_bytes:
        raise ValueError("dependency closure is not canonical JSON")
    dependency_closure = validate_dependency_closure(
        dependency_closure,
        [resolved_files[f"Repository {repository} database"] for repository in ("devario-core", "seafoam-labs")],
    )

    verify_signature(resolved_files["bootstrap signature"], bootstrap, bootstrap_keyring)
    for repository in ("devario-core", "seafoam-labs"):
        verify_signature(
            resolved_files[f"Repository {repository} database signature"],
            resolved_files[f"Repository {repository} database"],
            bootstrap_keyring,
        )
    if not args.core_keyring:
        raise ValueError("a core public-key bundle is required to verify Shelly bootstrap")
    core_public = args.core_keyring.resolve(strict=True) / "devario.gpg"
    active_path = args.core_keyring.resolve(strict=True) / "active-signer"
    active = active_path.read_text(encoding="ascii").strip()
    if not __import__("re").fullmatch(r"[0-9A-F]{40}(?:[0-9A-F]{24})?", active):
        raise ValueError("core active-signer is invalid")
    verify_signature(
        resolved_files["Shelly bootstrap signature"],
        resolved_files["Shelly bootstrap package"],
        core_public,
        active,
    )

    repositories = []
    keyrings = []
    if args.core_repo:
        repositories.append(closure(args.core_repo, "devario-core", symlinks=True))
    if args.seafoam_repo:
        repositories.append(closure(args.seafoam_repo, "seafoam-labs", symlinks=True))
    if args.managed_repo:
        repositories.append(closure(args.managed_repo, "devario-managed", symlinks=True))
    if args.core_keyring:
        keyrings.append(closure(args.core_keyring, "devario-core"))
    if args.seafoam_keyring:
        keyrings.append(closure(args.seafoam_keyring, "seafoam-labs"))
    if args.managed_keyring:
        keyrings.append(closure(args.managed_keyring, "devario-managed"))

    if args.operation == "iso":
        if args.release_version is None:
            raise ValueError("ISO input locks require an explicit release version")
        validate_release_version(args.release_version)
    elif args.release_version is not None:
        raise ValueError("release version is valid only for an ISO input lock")

    result = {
        "schemaVersion": 2,
        "isoBuilder": {k: v for k, v in json.loads((Path(__file__).resolve().parents[1] / "tools/devario-iso-builder/source.lock.json").read_text()).items() if k in ("repository", "revision", "sha256")},
        "operation": args.operation,
        "architecture": "x86_64",
        "core": core_identity,
        "edition": {"id": edition_id(edition), **edition_identity},
        "sourceManifest": {
            "path": "release/source-manifest.json",
            "sha256": sha256(source_manifest),
        },
        "sourceDateEpoch": args.source_date_epoch,
        "controlledBuilder": {
            "manifestSha256": hashlib.sha256(builder_manifest_bytes).hexdigest(),
            "manifestSignatureSha256": sha256(resolved_files["controlled builder manifest signature"]),
            "rootTreeSha256": builder_manifest["rootTreeSha256"],
            "dependencyClosureSha256": hashlib.sha256(dependency_bytes).hexdigest(),
            "dependencyClosure": dependency_closure,
        },
        "repositorySnapshot": {
            "url": args.repository_snapshot_url,
            "databases": [
                {
                    "repository": repository,
                    "sha256": sha256(resolved_files[f"Repository {repository} database"]),
                    "signatureSha256": sha256(resolved_files[f"Repository {repository} database signature"]),
                }
                for repository in ("devario-core", "seafoam-labs")
            ],
        },
        "bootstrap": {
            "url": args.bootstrap_url,
            "sha256": sha256(bootstrap),
            "size": bootstrap.stat().st_size,
            "signatureSha256": sha256(resolved_files["bootstrap signature"]),
        },
        "shellyBootstrap": {
            "sha256": sha256(resolved_files["Shelly bootstrap package"]),
            "size": resolved_files["Shelly bootstrap package"].stat().st_size,
            "signatureSha256": sha256(resolved_files["Shelly bootstrap signature"]),
        },
        "repositories": repositories,
        "keyrings": keyrings,
    }
    if args.operation == "iso":
        result["releaseVersion"] = args.release_version
    if args.managed_input_lock:
        managed_lock_path = args.managed_input_lock.resolve(strict=True)
        managed_lock_bytes = managed_lock_path.read_bytes()
        managed_lock_value = load_json_bytes(managed_lock_bytes)
        if managed_lock_bytes != canonical(managed_lock_value):
            raise ValueError("managed input lock is not canonical JSON")
        result["managedInputLockSha256"] = hashlib.sha256(managed_lock_bytes).hexdigest()
    for field in ("repositorySnapshot", "bootstrap", "shellyBootstrap", "isoBuilder"):
        if builder_manifest[field] != result[field]:
            raise ValueError(f"controlled builder manifest does not match locked {field}")
    if builder_manifest["dependencyClosureSha256"] != result["controlledBuilder"]["dependencyClosureSha256"]:
        raise ValueError("controlled builder manifest does not match dependency closure")
    lock_schema = load_json_bytes((script_dir / "schemas/core-input-lock.schema.json").read_bytes())
    Draft202012Validator(lock_schema).validate(result)
    return result


def canonical(data: object) -> bytes:
    return (json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n").encode()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--operation", choices=("packages", "external-packages", "iso"), required=True)
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--edition", type=Path, required=True)
    parser.add_argument("--bootstrap-archive", type=Path, required=True)
    parser.add_argument("--bootstrap-signature", type=Path, required=True)
    parser.add_argument("--bootstrap-url", required=True)
    parser.add_argument("--repository-snapshot-dir", type=Path, required=True)
    parser.add_argument("--repository-snapshot-url", required=True)
    parser.add_argument("--bootstrap-keyring", type=Path, required=True)
    parser.add_argument("--shelly-bootstrap", type=Path, required=True)
    parser.add_argument("--shelly-bootstrap-signature", type=Path, required=True)
    parser.add_argument("--builder-manifest", type=Path, required=True)
    parser.add_argument("--builder-manifest-signature", type=Path, required=True)
    parser.add_argument("--builder-keyring", type=Path)
    parser.add_argument("--builder-repository", choices=("devario-core", "devario-managed"), default="devario-core")
    parser.add_argument("--dependency-closure", type=Path, required=True)
    parser.add_argument("--source-date-epoch", type=int, required=True)
    parser.add_argument("--release-version")
    parser.add_argument("--core-repo", type=Path)
    parser.add_argument("--core-keyring", type=Path)
    parser.add_argument("--seafoam-repo", type=Path)
    parser.add_argument("--seafoam-keyring", type=Path)
    parser.add_argument("--managed-repo", type=Path)
    parser.add_argument("--managed-keyring", type=Path)
    parser.add_argument("--managed-input-lock", type=Path)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--output", type=Path)
    action.add_argument("--verify", type=Path)
    args = parser.parse_args()
    try:
        data = build(args)
        encoded = canonical(data)
        if args.verify:
            if args.verify.read_bytes() != encoded:
                print("Input lock does not match the current exact input closure.", file=sys.stderr)
                return 1
            print(f"Verified immutable input lock: {args.verify}")
        else:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            temporary = args.output.with_name(f".{args.output.name}.tmp")
            temporary.write_bytes(encoded)
            temporary.chmod(0o444)
            temporary.replace(args.output)
            print(f"Wrote immutable input lock: {args.output}")
    except (OSError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError, ValidationError, SchemaError) as error:
        print(f"Input-lock error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
