#!/usr/bin/env python3
"""Write a canonical, non-signing build-environment/output attestation."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

from jsonschema.exceptions import SchemaError, ValidationError


def no_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def output_closure(root: Path, excluded: set[Path]) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames.sort()
        filenames.sort()
        for name in list(dirnames):
            candidate = Path(directory) / name
            if candidate.is_symlink():
                dirnames.remove(name)
                filenames.append(name)
        for name in sorted(filenames):
            path = Path(directory) / name
            if path.resolve(strict=False) in {item.resolve(strict=False) for item in excluded}:
                continue
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                target = os.readlink(path)
                if "/" in target or not (path.parent / target).is_file():
                    raise ValueError(f"unsafe output symlink: {relative}")
                result.append({"path": relative, "mode": "120000", "target": target})
            elif stat.S_ISREG(mode):
                result.append(
                    {
                        "path": relative,
                        "mode": "100755" if mode & 0o111 else "100644",
                        "size": path.stat().st_size,
                        "sha256": digest(path),
                    }
                )
            else:
                raise ValueError(f"special output entry: {relative}")
    if not result:
        raise ValueError("build output closure is empty")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-lock", type=Path, required=True)
    parser.add_argument("--output-tree", type=Path, required=True)
    parser.add_argument("--builder-marker", type=Path, required=True)
    parser.add_argument("--builder-packages", type=Path, required=True)
    parser.add_argument("--operation", choices=("packages", "external-packages", "iso"), required=True)
    parser.add_argument("--managed-input-lock", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        lock_bytes = args.input_lock.read_bytes()
        lock = json.loads(lock_bytes, object_pairs_hook=no_duplicates)
        canonical_lock = (json.dumps(lock, sort_keys=True, separators=(",", ":")) + "\n").encode()
        if lock_bytes != canonical_lock or lock.get("operation") != args.operation:
            raise ValueError("input lock is non-canonical or belongs to another operation")
        from jsonschema import Draft202012Validator
        lock_schema = json.loads(
            (Path(__file__).parent / "schemas/core-input-lock.schema.json").read_text(),
            object_pairs_hook=no_duplicates,
        )
        Draft202012Validator(lock_schema).validate(lock)
        dependency_bytes = args.builder_packages.read_bytes()
        dependencies = json.loads(dependency_bytes, object_pairs_hook=no_duplicates)
        if dependency_bytes != (json.dumps(dependencies, sort_keys=True, separators=(",", ":")) + "\n").encode():
            raise ValueError("builder dependency closure must be canonical JSON")
        if hashlib.sha256(dependency_bytes).hexdigest() != lock["controlledBuilder"]["dependencyClosureSha256"]:
            raise ValueError("builder dependency closure differs from input lock")
        if digest(args.builder_marker) != lock["controlledBuilder"]["manifestSha256"]:
            raise ValueError("builder marker differs from the input-lock manifest")
        output_root = args.output_tree.resolve(strict=True)
        data = {
            "schemaVersion": 1,
            "operation": args.operation,
            "edition": lock["edition"]["id"],
            "inputLockSha256": hashlib.sha256(lock_bytes).hexdigest(),
            "coreCommit": lock["core"]["commit"],
            "sourceDateEpoch": lock["sourceDateEpoch"],
            "controlledBuilder": lock["controlledBuilder"],
            "archSnapshot": lock["archSnapshot"],
            "bootstrap": lock["bootstrap"],
            "shellyBootstrap": lock["shellyBootstrap"],
            "builderObservation": {
                "architecture": os.uname().machine,
                "markerSha256": digest(args.builder_marker),
                "packageInventorySha256": digest(args.builder_packages),
            },
            "outputs": output_closure(output_root, {args.output, Path(str(args.output) + ".sig")}),
        }
        if args.operation == "iso":
            data["releaseVersion"] = lock["releaseVersion"]
        managed_operation = args.operation == "external-packages" or (
            args.operation == "iso" and lock["edition"]["id"] == "managed"
        )
        if managed_operation:
            if args.managed_input_lock is None:
                raise ValueError("managed build attestation requires MANAGED-INPUT-LOCK.json")
            managed_bytes = args.managed_input_lock.read_bytes()
            managed_value = json.loads(managed_bytes, object_pairs_hook=no_duplicates)
            if managed_bytes != (json.dumps(managed_value, sort_keys=True, separators=(",", ":")) + "\n").encode():
                raise ValueError("managed input lock must be canonical JSON")
            data["managedInputLockSha256"] = hashlib.sha256(managed_bytes).hexdigest()
            if lock.get("managedInputLockSha256") not in (None, data["managedInputLockSha256"]):
                raise ValueError("core input lock and attestation disagree on managed input lock")
        schema = json.loads((Path(__file__).parent / "schemas/builder-attestation.schema.json").read_text(), object_pairs_hook=no_duplicates)
        Draft202012Validator(schema).validate(data)
        encoded = (json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n").encode()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.output.with_name(f".{args.output.name}.tmp")
        temporary.write_bytes(encoded)
        temporary.chmod(0o444)
        temporary.replace(args.output)
    except (OSError, ValueError, KeyError, json.JSONDecodeError, ValidationError, SchemaError) as error:
        print(f"Builder-attestation error: {error}", file=sys.stderr)
        return 1
    print(f"Wrote builder attestation: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
