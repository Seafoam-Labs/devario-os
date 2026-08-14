#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
test_root="$(mktemp -d /tmp/devario-input-lock.XXXXXX)"
cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT

PROJECT_DIR="$project_dir" TEST_ROOT="$test_root" python3 - <<'PY'
import importlib.util
import io
import json
import os
import pathlib
import tarfile

from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError

project = pathlib.Path(os.environ["PROJECT_DIR"])
root = pathlib.Path(os.environ["TEST_ROOT"])
spec = importlib.util.spec_from_file_location("core_input_lock", project / "scripts/core-input-lock.py")
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def database(path: pathlib.Path, name: str, version: str) -> None:
    payload = f"%NAME%\n{name}\n\n%VERSION%\n{version}\n\n%ARCH%\nx86_64\n\n".encode()
    with tarfile.open(path, "w:gz") as archive:
        record = tarfile.TarInfo(f"{name}-{version}/desc")
        record.size = len(payload)
        record.mode = 0o644
        archive.addfile(record, io.BytesIO(payload))

core = root / "core.db"; extra = root / "extra.db"
database(core, "base", "1-1")
database(extra, "git", "2-1")
valid = [
    {"name": "base", "version": "1-1", "architecture": "x86_64"},
    {"name": "git", "version": "2-1", "architecture": "x86_64"},
]
assert module.validate_dependency_closure(valid, [core, extra]) == valid
tampered = [dict(item) for item in valid]
tampered[1]["version"] = "999-1"
try:
    module.validate_dependency_closure(tampered, [core, extra])
except ValueError as error:
    assert "absent from locked" in str(error)
else:
    raise AssertionError("fabricated dependency version was accepted")

try:
    module.load_json_bytes(b'{"schemaVersion":1,"schemaVersion":2}\n')
except ValueError as error:
    assert "duplicate JSON key" in str(error)
else:
    raise AssertionError("duplicate JSON keys were accepted")

module.validate_credential_free_https_url("https://archive.archlinux.org/bootstrap-2026.08.14.tar.zst", reject_latest=True)
for unsafe_url in (
    "https://user:password@example.test/bootstrap.tar.zst",
    "https://example.test/bootstrap.tar.zst?token=secret",
    "https://example.test/bootstrap.tar.zst#fragment",
    "https://example.test/latest/bootstrap.tar.zst",
    "https://example.test/%2e%2e/bootstrap.tar.zst",
):
    try:
        module.validate_credential_free_https_url(unsafe_url, reject_latest=True)
    except ValueError:
        pass
    else:
        raise AssertionError(f"unsafe bootstrap URL was accepted: {unsafe_url}")

for release_version in ("test", "1.0.0", "2026.08.14-rc.1"):
    module.validate_release_version(release_version)
for unsafe_version in ("", "2026 08", "../2026", "2026@prod", "2026+prod", "x" * 65):
    try:
        module.validate_release_version(unsafe_version)
    except ValueError:
        pass
    else:
        raise AssertionError(f"unsafe release version was accepted: {unsafe_version}")

schema = json.loads((project / "scripts/schemas/core-input-lock.schema.json").read_text())
url_schema = dict(schema["$defs"]["signedInputWithUrl"])
url_schema["$defs"] = schema["$defs"]
url_validator = Draft202012Validator(url_schema)
for unsafe_url in (
    "https://user@example.test/bootstrap.tar.zst",
    "https://example.test/bootstrap.tar.zst?token=value",
    "https://example.test/bootstrap.tar.zst#fragment",
    "https://example.test/%2e%2e/bootstrap.tar.zst",
):
    try:
        url_validator.validate(
            {"url": unsafe_url, "sha256": "0" * 64, "size": 1, "signatureSha256": "1" * 64}
        )
    except ValidationError:
        pass
    else:
        raise AssertionError(f"input-lock schema accepted unsafe URL: {unsafe_url}")
file_schema = dict(schema["$defs"]["file"])
file_schema["$defs"] = schema["$defs"]
file_validator = Draft202012Validator(file_schema)
for invalid in (
    {"path": "regular", "mode": "100644"},
    {"path": "link", "mode": "120000", "target": "file", "size": 1, "sha256": "0" * 64},
):
    try:
        file_validator.validate(invalid)
    except ValidationError:
        pass
    else:
        raise AssertionError(f"invalid closure entry was accepted: {invalid}")
PY

echo 'Core input-lock semantic tests passed.'
