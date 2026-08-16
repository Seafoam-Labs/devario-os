#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
manifest=/run/devario-controlled-builder/manifest.json
manifest_signature=/run/devario-controlled-builder/manifest.json.sig
input_lock=/input/CORE-INPUT-LOCK.json
repository_name="${DEVARIO_REPOSITORY_NAME:-devario-core}"
keyring_dir="${DEVARIO_KEYRING_DIR:-}"

if [[ "${DEVARIO_CONTROLLED_NSPAWN:-0}" != 1 ]]; then
  echo 'Release construction is permitted only inside the controlled nspawn wrapper.' >&2
  exit 1
fi
for path in "$manifest" "$manifest_signature" "$input_lock"; do
  [[ -f "$path" && ! -L "$path" ]] || { echo "Unsafe controlled-builder input: $path" >&2; exit 1; }
  if [[ "$(stat -c '%u' "$path")" != 0 || "$(stat -c '%a' "$path")" != 444 ]]; then
    echo "Controlled-builder input must be root-owned mode 0444: $path" >&2
    exit 1
  fi
done
[[ -n "$keyring_dir" ]] || { echo 'Controlled builder requires an explicit public-key bundle.' >&2; exit 1; }
# shellcheck source=lib/repository.sh
source "$script_dir/lib/repository.sh"
devario_validate_keyring_bundle "$keyring_dir" "$repository_name" production
devario_gpgv_active_signature "$manifest_signature" "$manifest"
[[ ! -e /.devario-controlled-builder-consumed ]] || {
  echo 'This controlled builder has already been consumed.' >&2
  exit 1
}

actual_root_tree="$($script_dir/tree-closure-digest.py --root / \
  --exclude dev --exclude proc --exclude sys --exclude run --exclude tmp \
  --exclude var/tmp --exclude input --exclude output --exclude signing \
  --exclude etc/resolv.conf --exclude etc/devario/controlled-builder.json \
  --exclude etc/devario/controlled-builder.json.sig)"

MANIFEST_SIGNATURE="$manifest_signature" \
ACTUAL_ROOT_TREE="$actual_root_tree" \
EXPECTED_OPERATION="${DEVARIO_EXPECTED_OPERATION:-packages}" \
EXPECTED_CORE_COMMIT="${DEVARIO_CORE_COMMIT:-}" \
EXPECTED_MANAGED_COMMIT="${DEVARIO_MANAGED_COMMIT:-}" \
EXPECTED_SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}" \
EXPECTED_RELEASE_VERSION="${DEVARIO_RELEASE_VERSION:-}" \
python3 - "$manifest" "$input_lock" "$script_dir/schemas" <<'PY'
import hashlib, json, os, pathlib, platform, sys
from jsonschema import Draft202012Validator
def no_duplicates(pairs):
 result={}
 for key,value in pairs:
  if key in result: raise SystemExit(f"duplicate JSON key: {key}")
  result[key]=value
 return result
manifest_path, lock_path, schemas=map(pathlib.Path, sys.argv[1:])
manifest_bytes=manifest_path.read_bytes(); lock_bytes=lock_path.read_bytes()
manifest=json.loads(manifest_bytes,object_pairs_hook=no_duplicates); lock=json.loads(lock_bytes,object_pairs_hook=no_duplicates)
canonical=lambda value:(json.dumps(value,sort_keys=True,separators=(",",":"))+"\n").encode()
if manifest_bytes != canonical(manifest) or lock_bytes != canonical(lock): raise SystemExit("controlled-builder inputs must be canonical JSON")
Draft202012Validator(json.loads((schemas/"controlled-builder.schema.json").read_text(),object_pairs_hook=no_duplicates)).validate(manifest)
Draft202012Validator(json.loads((schemas/"core-input-lock.schema.json").read_text(),object_pairs_hook=no_duplicates)).validate(lock)
controlled=lock["controlledBuilder"]
if hashlib.sha256(manifest_bytes).hexdigest() != controlled["manifestSha256"]: raise SystemExit("input lock does not bind the builder manifest")
if hashlib.sha256(pathlib.Path(os.environ["MANIFEST_SIGNATURE"]).read_bytes()).hexdigest() != controlled["manifestSignatureSha256"]: raise SystemExit("input lock does not bind the builder-manifest signature")
if manifest["rootTreeSha256"] != controlled["rootTreeSha256"]: raise SystemExit("builder root identity differs from input lock")
if manifest["rootTreeSha256"] != os.environ["ACTUAL_ROOT_TREE"]: raise SystemExit("live builder root differs from authenticated builder identity")
for key in ("archSnapshot", "bootstrap", "shellyBootstrap"):
 if manifest[key] != lock[key]: raise SystemExit(f"builder {key} differs from input lock")
if manifest["dependencyClosureSha256"] != controlled["dependencyClosureSha256"]: raise SystemExit("builder dependency closure differs from input lock")
if lock["operation"] != os.environ["EXPECTED_OPERATION"]: raise SystemExit("controlled operation differs from input lock")
if lock["core"]["commit"] != os.environ["EXPECTED_CORE_COMMIT"]: raise SystemExit("core commit environment differs from input lock")
if str(lock["sourceDateEpoch"]) != os.environ["EXPECTED_SOURCE_DATE_EPOCH"]: raise SystemExit("SOURCE_DATE_EPOCH differs from input lock")
release_version=os.environ["EXPECTED_RELEASE_VERSION"]
if lock["operation"] == "iso":
 if lock["releaseVersion"] != release_version: raise SystemExit("release version environment differs from input lock")
elif release_version: raise SystemExit("release version supplied for a non-ISO controlled operation")
managed=os.environ["EXPECTED_MANAGED_COMMIT"]
managed_operation=lock["operation"] == "external-packages" or lock["edition"]["id"] == "managed"
if managed_operation and lock["edition"]["commit"] != managed: raise SystemExit("managed commit environment differs from input lock")
if not managed_operation and managed: raise SystemExit("managed commit supplied for a core-only operation")
if lock["operation"] == "iso" and lock["edition"]["id"] == "managed":
 managed_lock=pathlib.Path("/input/MANAGED-INPUT-LOCK.json")
 info=managed_lock.lstat()
 if not managed_lock.is_file() or managed_lock.is_symlink() or info.st_uid != 0 or info.st_mode & 0o777 != 0o444: raise SystemExit("managed input lock is not a root-owned mode-0444 regular file")
 managed_bytes=managed_lock.read_bytes(); managed_value=json.loads(managed_bytes,object_pairs_hook=no_duplicates)
 if managed_bytes != canonical(managed_value): raise SystemExit("managed input lock must be canonical JSON")
 if hashlib.sha256(managed_bytes).hexdigest() != lock["managedInputLockSha256"]: raise SystemExit("managed input lock differs from CORE input lock binding")
if platform.machine() != lock["architecture"]: raise SystemExit("live builder architecture differs from input lock")
def sha(path):
 value=hashlib.sha256()
 with path.open("rb") as stream:
  for block in iter(lambda:stream.read(1024*1024),b""): value.update(block)
 return value.hexdigest()
for database in lock["archSnapshot"]["databases"]:
 path=pathlib.Path("/var/lib/shelly/sync")/(database["repository"]+".db")
 if sha(path) != database["sha256"]: raise SystemExit(f"live {database['repository']} database differs from input lock")
records=[]
for desc in sorted(pathlib.Path("/var/lib/shelly/local").glob("*/desc")):
 lines=desc.read_text(encoding="utf-8").splitlines(); fields={}; index=0
 while index < len(lines):
  if lines[index].startswith("%") and lines[index].endswith("%") and index+1 < len(lines):
   fields[lines[index][1:-1]]=lines[index+1]; index+=2
  else: index+=1
 if not all(fields.get(key) for key in ("NAME","VERSION","ARCH")): raise SystemExit(f"incomplete installed builder package record: {desc}")
 records.append({"name":fields["NAME"],"version":fields["VERSION"],"architecture":fields["ARCH"]})
records.sort(key=lambda item:item["name"])
if records != controlled["dependencyClosure"]: raise SystemExit("live installed builder package closure differs from input lock")
if hashlib.sha256(canonical(records)).hexdigest() != controlled["dependencyClosureSha256"]: raise SystemExit("live builder package-closure digest differs from input lock")
PY
echo 'Authenticated controlled-builder manifest matches the immutable input lock.'
