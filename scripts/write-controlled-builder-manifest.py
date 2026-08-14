#!/usr/bin/env python3
"""Create the root-owned manifest for a fresh, one-shot nspawn builder."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

from jsonschema import Draft202012Validator
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root-tree-sha256", required=True)
    parser.add_argument("--arch-snapshot-url", required=True)
    parser.add_argument("--arch-snapshot-dir", type=Path, required=True)
    parser.add_argument("--bootstrap-archive", type=Path, required=True)
    parser.add_argument("--bootstrap-signature", type=Path, required=True)
    parser.add_argument("--bootstrap-url", required=True)
    parser.add_argument("--shelly-bootstrap", type=Path, required=True)
    parser.add_argument("--shelly-bootstrap-signature", type=Path, required=True)
    parser.add_argument("--dependency-closure", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        closure_bytes = args.dependency_closure.read_bytes()
        closure = json.loads(closure_bytes, object_pairs_hook=no_duplicates)
        canonical_closure = (json.dumps(closure, sort_keys=True, separators=(",", ":")) + "\n").encode()
        if closure_bytes != canonical_closure:
            raise ValueError("dependency closure is not canonical JSON")
        data = {
            "schemaVersion": 1,
            "architecture": "x86_64",
            "rootTreeSha256": args.root_tree_sha256,
            "archSnapshot": {
                "url": args.arch_snapshot_url,
                "databases": [
                    {
                        "repository": repository,
                        "sha256": digest(args.arch_snapshot_dir / f"{repository}.db"),
                        "signatureSha256": digest(args.arch_snapshot_dir / f"{repository}.db.sig"),
                    }
                    for repository in ("core", "extra")
                ],
            },
            "bootstrap": {
                "url": args.bootstrap_url,
                "sha256": digest(args.bootstrap_archive),
                "size": args.bootstrap_archive.stat().st_size,
                "signatureSha256": digest(args.bootstrap_signature),
            },
            "shellyBootstrap": {
                "sha256": digest(args.shelly_bootstrap),
                "size": args.shelly_bootstrap.stat().st_size,
                "signatureSha256": digest(args.shelly_bootstrap_signature),
            },
            "dependencyClosureSha256": hashlib.sha256(closure_bytes).hexdigest(),
        }
        schema = json.loads((Path(__file__).parent / "schemas/controlled-builder.schema.json").read_text(), object_pairs_hook=no_duplicates)
        Draft202012Validator(schema).validate(data)
        encoded = (json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n").encode()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(encoded)
        args.output.chmod(0o444)
    except (OSError, ValueError, json.JSONDecodeError, ValidationError, SchemaError) as error:
        print(f"Controlled-builder manifest error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
