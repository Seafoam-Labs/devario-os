#!/usr/bin/env python3
"""Validate a JSON document with its declared Draft 2020-12 schema."""

from __future__ import annotations

import json
import pathlib
import sys

try:
    import jsonschema
except ImportError as error:  # pragma: no cover - exercised by shell diagnostics
    raise SystemExit("python3-jsonschema is required") from error


def reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate object key: {key}")
        result[key] = value
    return result


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} SCHEMA DOCUMENT", file=sys.stderr)
        return 2

    schema_path = pathlib.Path(sys.argv[1])
    document_path = pathlib.Path(sys.argv[2])
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)
        document = json.loads(document_path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)
        validator_class = jsonschema.validators.validator_for(schema)
        validator_class.check_schema(schema)
        validator = validator_class(schema, format_checker=jsonschema.FormatChecker())
        errors = sorted(validator.iter_errors(document), key=lambda item: list(item.absolute_path))
    except (OSError, ValueError, json.JSONDecodeError, jsonschema.SchemaError) as error:
        print(f"JSON validation setup failed: {error}", file=sys.stderr)
        return 1

    if errors:
        for error in errors:
            location = "/".join(str(part) for part in error.absolute_path) or "<document>"
            print(f"{document_path}:{location}: {error.message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
