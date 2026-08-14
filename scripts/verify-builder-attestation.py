#!/usr/bin/env python3
"""Semantically verify a signed builder attestation and exact output tree."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
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


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--attestation", type=Path, required=True)
    parser.add_argument("--input-lock", type=Path, required=True)
    parser.add_argument("--output-tree", type=Path, required=True)
    args = parser.parse_args()
    try:
        output_root = args.output_tree.resolve(strict=True)
        if args.input_lock.resolve(strict=True) != output_root / "CORE-INPUT-LOCK.json" \
                or args.attestation.resolve(strict=True) != output_root / "BUILDER-ATTESTATION.json":
            raise ValueError("lock and attestation must use canonical paths inside output tree")
        attestation_bytes = args.attestation.read_bytes()
        lock_bytes = args.input_lock.read_bytes()
        attestation = json.loads(attestation_bytes, object_pairs_hook=no_duplicates)
        lock = json.loads(lock_bytes, object_pairs_hook=no_duplicates)
        if canonical(attestation) != attestation_bytes or canonical(lock) != lock_bytes:
            raise ValueError("attestation and lock must be canonical JSON")
        schemas = Path(__file__).parent / "schemas"
        Draft202012Validator(json.loads((schemas / "builder-attestation.schema.json").read_text(), object_pairs_hook=no_duplicates)).validate(attestation)
        Draft202012Validator(json.loads((schemas / "core-input-lock.schema.json").read_text(), object_pairs_hook=no_duplicates)).validate(lock)
        if attestation["inputLockSha256"] != hashlib.sha256(lock_bytes).hexdigest():
            raise ValueError("attestation does not bind the supplied input lock")
        if attestation["operation"] != lock["operation"]:
            raise ValueError("attestation operation differs from input lock")
        if attestation["edition"] != lock["edition"]["id"]:
            raise ValueError("attestation edition differs from input lock")
        if attestation["coreCommit"] != lock["core"]["commit"] \
            or attestation["sourceDateEpoch"] != lock["sourceDateEpoch"]:
            raise ValueError("attestation source identity differs from input lock")
        if attestation["operation"] == "iso" and \
                attestation["releaseVersion"] != lock["releaseVersion"]:
            raise ValueError("attestation release version differs from input lock")
        for field in ("controlledBuilder", "archSnapshot", "bootstrap", "shellyBootstrap"):
            if attestation[field] != lock[field]:
                raise ValueError(f"attestation {field} differs from input lock")
        if attestation["builderObservation"]["markerSha256"] != lock["controlledBuilder"]["manifestSha256"] \
                or attestation["builderObservation"]["packageInventorySha256"] != lock["controlledBuilder"]["dependencyClosureSha256"]:
            raise ValueError("builder observation does not bind the locked manifest/dependency closure")
        manifest_path = args.output_tree / "CONTROLLED-BUILDER.json"
        manifest_signature_path = args.output_tree / "CONTROLLED-BUILDER.json.sig"
        manifest_bytes = manifest_path.read_bytes()
        manifest = json.loads(manifest_bytes, object_pairs_hook=no_duplicates)
        if canonical(manifest) != manifest_bytes:
            raise ValueError("CONTROLLED-BUILDER.json must be canonical JSON")
        Draft202012Validator(
            json.loads((schemas / "controlled-builder.schema.json").read_text(), object_pairs_hook=no_duplicates)
        ).validate(manifest)
        if hashlib.sha256(manifest_bytes).hexdigest() != lock["controlledBuilder"]["manifestSha256"] \
                or hashlib.sha256(manifest_signature_path.read_bytes()).hexdigest() != lock["controlledBuilder"]["manifestSignatureSha256"]:
            raise ValueError("closed controlled-builder evidence differs from the input lock")
        if manifest["rootTreeSha256"] != lock["controlledBuilder"]["rootTreeSha256"] \
                or manifest["dependencyClosureSha256"] != lock["controlledBuilder"]["dependencyClosureSha256"]:
            raise ValueError("controlled-builder identity differs from the input lock")
        for field in ("archSnapshot", "bootstrap", "shellyBootstrap"):
            if manifest[field] != lock[field]:
                raise ValueError(f"controlled-builder manifest {field} differs from input lock")
        if attestation["operation"] == "external-packages" or (
            attestation["operation"] == "iso" and lock["edition"]["id"] == "managed"
        ):
            managed_lock = args.output_tree / "MANAGED-INPUT-LOCK.json"
            managed_bytes = managed_lock.read_bytes()
            managed_value = json.loads(managed_bytes, object_pairs_hook=no_duplicates)
            if canonical(managed_value) != managed_bytes:
                raise ValueError("MANAGED-INPUT-LOCK.json must be canonical JSON")
            if attestation["managedInputLockSha256"] != hashlib.sha256(managed_bytes).hexdigest():
                raise ValueError("attestation does not bind MANAGED-INPUT-LOCK.json")
            if attestation["operation"] == "iso" and \
                    lock.get("managedInputLockSha256") != attestation["managedInputLockSha256"]:
                raise ValueError("core input lock does not bind MANAGED-INPUT-LOCK.json")

        module_spec = importlib.util.spec_from_file_location(
            "devario_attestation_writer", Path(__file__).parent / "write-builder-attestation.py"
        )
        if module_spec is None or module_spec.loader is None:
            raise ValueError("cannot load output-closure verifier")
        module = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(module)
        excluded = {args.attestation, Path(str(args.attestation) + ".sig")}
        actual = module.output_closure(output_root, excluded)
        if actual != attestation["outputs"]:
            raise ValueError("attested output closure differs from finalized bytes/modes")
    except (OSError, ValueError, KeyError, json.JSONDecodeError, ValidationError, SchemaError) as error:
        print(f"Builder-attestation verification error: {error}", file=sys.stderr)
        return 1
    print("Builder attestation and exact output closure verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
