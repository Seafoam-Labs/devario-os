#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root_dir=''
iso_path=''
edition=community
package_inventory=''
expected_inventory=''
write_inventory=''
release_validation=0
input_lock=''
core_keyring=''
managed_keyring=''
expected_core_url=''
expected_managed_url=''
expected_release_version=''

usage() {
  cat <<'EOF'
Usage: verify-image-boundary.sh (--root DIR | --iso FILE) [options]

Scan the complete installed/live root for private keys, customer/tenant data,
and managed-product leakage. The ISO form also extracts and canonicalizes the
exact Devario package inventory.

Options:
  --edition ID                  community or managed (default: community)
  --release                     require embedded release-mode source/trust record
  --input-lock FILE             exact CORE-INPUT-LOCK.json for release binding
  --core-keyring DIR            expected core public-key bundle
  --managed-keyring DIR         expected managed public-key bundle
  --core-url URL                exact installed core repository URL
  --managed-url URL             exact installed managed repository URL
  --release-version VERSION     exact release identity expected by candidate
  --expected-inventory FILE     exact canonical name/version/arch/license JSON
  --write-inventory FILE        write canonical IMAGE-PACKAGE-INVENTORY.json
EOF
}

while (( $# )); do
  case "$1" in
    --root) (( $# >= 2 )) || exit 2; root_dir="$2"; shift 2 ;;
    --iso) (( $# >= 2 )) || exit 2; iso_path="$2"; shift 2 ;;
    --edition) (( $# >= 2 )) || exit 2; edition="$2"; shift 2 ;;
    --package-inventory) (( $# >= 2 )) || exit 2; package_inventory="$2"; shift 2 ;;
    --expected-inventory) (( $# >= 2 )) || exit 2; expected_inventory="$2"; shift 2 ;;
    --write-inventory) (( $# >= 2 )) || exit 2; write_inventory="$2"; shift 2 ;;
    --release) release_validation=1; shift ;;
    --input-lock) input_lock="$2"; shift 2 ;;
    --core-keyring) core_keyring="$2"; shift 2 ;;
    --managed-keyring) managed_keyring="$2"; shift 2 ;;
    --core-url) expected_core_url="$2"; shift 2 ;;
    --managed-url) expected_managed_url="$2"; shift 2 ;;
    --release-version) expected_release_version="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$edition" != community && "$edition" != managed ]]; then
  echo 'Edition must be community or managed.' >&2
  exit 2
fi
if { [[ -n "$root_dir" ]] && [[ -n "$iso_path" ]]; } \
  || { [[ -z "$root_dir" ]] && [[ -z "$iso_path" ]]; }; then
  echo 'Select exactly one of --root or --iso.' >&2
  exit 2
fi
for command_name in find grep python3 sort; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

temporary_dir=''
cleanup() { [[ -z "$temporary_dir" ]] || rm -rf -- "$temporary_dir"; }
trap cleanup EXIT

if [[ -n "$iso_path" ]]; then
  for command_name in bsdtar unsquashfs; do
    command -v "$command_name" >/dev/null 2>&1 || {
      echo "$command_name is required to inspect an ISO." >&2
      exit 1
    }
  done
  iso_path="$(realpath -e -- "$iso_path")"
  temporary_dir="$(mktemp -d /tmp/devario-image-boundary.XXXXXX)"
  iso_tree="$temporary_dir/iso"
  root_dir="$temporary_dir/root"
  install -d -m 0755 "$iso_tree" "$root_dir"
  bsdtar -xf "$iso_path" -C "$iso_tree"
  mapfile -t squashfs_images < <(find "$iso_tree" -type f -name 'airootfs.sfs' -print)
  mapfile -t inventories < <(find "$iso_tree" -type f -name 'pkglist.x86_64.txt' -print)
  if (( ${#squashfs_images[@]} != 1 || ${#inventories[@]} != 1 )); then
    echo 'The ISO must contain exactly one root SquashFS and one x86_64 package inventory.' >&2
    exit 1
  fi
  unsquashfs -no-progress -d "$root_dir" "${squashfs_images[0]}" >/dev/null
  package_inventory="${inventories[0]}"
else
  root_dir="$(realpath -e -- "$root_dir")"
fi

if [[ ! -d "$root_dir" || -L "$root_dir" ]]; then
  echo "Image root is unavailable or unsafe: $root_dir" >&2
  exit 1
fi
"$script_dir/reject-secret-material.py" --tree "$root_dir"

if find -P "$root_dir" -mindepth 1 \
  \( -type b -o -type c -o -type p -o -type s \) -print -quit | grep -q .; then
  echo 'The finalized image tree contains a device, FIFO, or socket.' >&2
  exit 1
fi

# Customer identity and enrollment credentials are forbidden in every final
# image, including Managed images. Only product/repository names are an
# edition-specific Community prohibition. Scan the complete root in chunks so
# arbitrary filenames and binary payloads cannot bypass the boundary.
if ! IMAGE_ROOT="$root_dir" EDITION="$edition" python3 - <<'PY'
import os, pathlib, re

root = pathlib.Path(os.environ["IMAGE_ROOT"])
edition = os.environ["EDITION"]
customer_path = re.compile(
    r"(^|[/_.-])(?:tenant|customer|enrollment)[_.-]"
    r"(?:id|name|url|token|secret|credential|credentials|key|api[_.-]?key)([/_.-]|$)",
    re.I,
)
managed_path = re.compile(
    r"(^|[/_.-])(?:devario[_.-]?managed|managed[_.-]?keyring)([/_.-]|$)", re.I
)
customer_bytes = re.compile(
    br"(?:tenant|customer|enrollment)[_.-]"
    br"(?:id|name|url|token|secret|credential|credentials|key|api[_.-]?key)",
    re.I,
)
managed_bytes = re.compile(br"devario[_.-]?managed|managed[_.-]?keyring", re.I)
credential_bytes = re.compile(
    br"https?://[^\s/@:]+(?::[^\s/@]+)?@[A-Za-z0-9.-]+"
    br"|\bAuthorization\s*:\s*Bearer\s+[A-Za-z0-9._~+/=-]{8,}"
    br"|\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"
    br"|glpat-[A-Za-z0-9_-]{20,}|AKIA[A-Z0-9]{16}"
    br"|xox[baprs]-[A-Za-z0-9-]{10,}|sk_live_[A-Za-z0-9]{16,})\b"
    br"|\beyJ[A-Za-z0-9_-]{9,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}\b",
    re.I,
)

for path in root.rglob("*"):
    relative = path.relative_to(root).as_posix()
    if customer_path.search(relative):
        raise SystemExit(f"customer/enrollment pathname is forbidden: {relative}")
    if edition == "community" and managed_path.search(relative):
        raise SystemExit(f"Managed-product pathname is forbidden in Community: {relative}")
    if not path.is_file() or path.is_symlink():
        continue
    try:
        with path.open("rb") as stream:
            tail = b""
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                data = tail + block
                if customer_bytes.search(data) or credential_bytes.search(data):
                    raise SystemExit(f"customer/enrollment credential content is forbidden: {relative}")
                if edition == "community" and managed_bytes.search(data):
                    raise SystemExit(f"Managed-product content is forbidden in Community: {relative}")
                tail = data[-512:]
    except OSError as error:
        raise SystemExit(f"cannot scan finalized image file {relative}: {error}") from error
PY
then
  echo 'Final image contains managed leakage or customer/credential material.' >&2
  exit 1
fi

shelly_config="$root_dir/etc/pacman.conf"
if [[ ! -f "$shelly_config" || -L "$shelly_config" ]]; then
  echo 'The image does not contain a safe /etc/pacman.conf.' >&2
  exit 1
fi
SHELLY_CONFIG="$shelly_config" EDITION="$edition" EXPECTED_CORE_URL="$expected_core_url" EXPECTED_MANAGED_URL="$expected_managed_url" python3 -c 'import os, re
from urllib.parse import urlsplit
lines=open(os.environ["SHELLY_CONFIG"], encoding="utf-8").read().splitlines()
sections={}
current=None
for raw in lines:
 line=raw.strip()
 if not line or line.startswith("#"): continue
 match=re.fullmatch(r"\[([^]]+)\]", line)
 if match:
  current=match.group(1); sections.setdefault(current, []); continue
 if current: sections[current].append(line)
required=["devario-core"] + (["devario-managed"] if os.environ["EDITION"] == "managed" else [])
if set(sections) != {"options", *required}: raise SystemExit("unexpected repository section")
for name in required:
 values=sections.get(name)
 if values is None: raise SystemExit(f"missing repository section: {name}")
 sig=[line for line in values if line.startswith("SigLevel")]
 servers=[line for line in values if line.startswith("Server")]
 if sig != ["SigLevel = Required"]: raise SystemExit(f"{name} must have exactly SigLevel = Required")
 if len(servers) != 1 or not servers[0].startswith("Server = "):
  raise SystemExit(f"{name} must have one credential-free HTTPS server")
 url=servers[0][len("Server = "):]
 if not re.fullmatch(r"https://(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?::[0-9]{1,5})?(?:/[A-Za-z0-9._~!$&\x27()*+,;=:/-]*)?",url):
  raise SystemExit(f"{name} server URL is not canonical credential-free HTTPS")
 parsed=urlsplit(url)
 try: port=parsed.port
 except ValueError: raise SystemExit(f"{name} server URL has an invalid port")
 if parsed.username is not None or parsed.password is not None or parsed.query or parsed.fragment or (port is not None and not 1<=port<=65535) or "//" in parsed.path or any(part in (".","..") for part in parsed.path.split("/")):
  raise SystemExit(f"{name} server URL is not canonical credential-free HTTPS")
 expected=os.environ["EXPECTED_CORE_URL"] if name == "devario-core" else os.environ["EXPECTED_MANAGED_URL"]
 if expected and servers != ["Server = " + expected]: raise SystemExit(f"{name} URL differs from release evidence")
if os.environ["EDITION"] == "community" and "devario-managed" in sections:
 raise SystemExit("Community image contains the managed repository section")'

canonical_inventory="$(mktemp /tmp/devario-package-inventory.XXXXXX)"
IMAGE_ROOT="$root_dir" python3 - > "$canonical_inventory" <<'PY'
import json,os,pathlib
root=pathlib.Path(os.environ["IMAGE_ROOT"])/"var/lib/pacman/local"
records=[]
for desc in sorted(root.glob("*/desc")):
 lines=desc.read_text(encoding="utf-8").splitlines(); fields={}; i=0
 while i < len(lines):
  line=lines[i]
  if line.startswith("%") and line.endswith("%"):
   key=line[1:-1]; i+=1; values=[]
   while i < len(lines) and lines[i] != "": values.append(lines[i]); i+=1
   fields[key]=values
  i+=1
 required={key:(fields.get(key) or [""])[0] for key in ("NAME","VERSION","ARCH")}
 if not all(required.values()): raise SystemExit(f"incomplete installed package record: {desc}")
 records.append({"name":required["NAME"],"version":required["VERSION"],"architecture":required["ARCH"],
  "packageBase":(fields.get("BASE") or [required["NAME"]])[0],"licenses":sorted(fields.get("LICENSE",[])),
  "packager":(fields.get("PACKAGER") or [""])[0]})
records.sort(key=lambda item:item["name"])
if not records or len(records)!=len({item["name"] for item in records}): raise SystemExit("installed package inventory is empty or ambiguous")
print(json.dumps(records,sort_keys=True,separators=(",",":")))
PY
if [[ -n "$package_inventory" ]]; then
  PACKAGE_LIST="$package_inventory" JSON_INVENTORY="$canonical_inventory" python3 - <<'PY'
import json,os,re
expected={(item["name"],item["version"]) for item in json.load(open(os.environ["JSON_INVENTORY"]))}
actual=set()
for number,line in enumerate(open(os.environ["PACKAGE_LIST"]),1):
 match=re.fullmatch(r"([^ ]+) ([^\s]+)\n?",line)
 if not match or (match.group(1),match.group(2)) in actual: raise SystemExit(f"invalid Devario package-list line {number}")
 actual.add((match.group(1),match.group(2)))
if actual != expected: raise SystemExit("Devario package list differs from installed local database closure")
PY
fi
if [[ -n "$expected_inventory" ]]; then
  [[ -f "$expected_inventory" && ! -L "$expected_inventory" ]] || { echo 'Expected inventory is unsafe.' >&2; exit 1; }
  if ! cmp -s "$canonical_inventory" "$expected_inventory"; then
    echo 'The installed package inventory differs from the exact expected inventory.' >&2
    diff -u "$expected_inventory" "$canonical_inventory" >&2 || true
    exit 1
  fi
fi
if [[ -n "$write_inventory" ]]; then
  install -d -m 0755 "$(dirname -- "$write_inventory")"
  install -m 0444 "$canonical_inventory" "$write_inventory"
fi

if (( release_validation )); then
  for value in "$input_lock" "$core_keyring" "$expected_core_url" "$expected_release_version"; do
    [[ -n "$value" ]] || { echo 'Release image validation is missing lock/core trust/URL evidence.' >&2; exit 2; }
  done
  if [[ "$edition" == managed ]] && { [[ -z "$managed_keyring" ]] || [[ -z "$expected_managed_url" ]]; }; then
    echo 'Managed release validation requires managed trust and URL evidence.' >&2; exit 2
  fi
  record="$root_dir/usr/share/devario/build-source.json"
  [[ -f "$record" && ! -L "$record" ]] || { echo 'Release image lacks its embedded build-source record.' >&2; exit 1; }
  source "$script_dir/lib/repository.sh"
  devario_validate_keyring_bundle "$core_keyring" devario-core production
  core_active="$DEVARIO_ACTIVE_SIGNER"; core_public="$DEVARIO_KEYRING_PUBLIC"
  core_trusted="$DEVARIO_KEYRING_TRUSTED"; core_revoked="$DEVARIO_KEYRING_REVOKED"
  core_active_file="$DEVARIO_KEYRING_ACTIVE"
  core_fingerprints=("${DEVARIO_PUBLIC_FINGERPRINTS[@]}")
  managed_active=''; managed_public=''
  managed_trusted=''; managed_revoked=''; managed_active_file=''
  if [[ "$edition" == managed ]]; then
    devario_validate_keyring_bundle "$managed_keyring" devario-managed production
    managed_active="$DEVARIO_ACTIVE_SIGNER"; managed_public="$DEVARIO_KEYRING_PUBLIC"
    managed_trusted="$DEVARIO_KEYRING_TRUSTED"; managed_revoked="$DEVARIO_KEYRING_REVOKED"
    managed_active_file="$DEVARIO_KEYRING_ACTIVE"
    managed_fingerprints=("${DEVARIO_PUBLIC_FINGERPRINTS[@]}")
    [[ "$core_active" != "$managed_active" ]] || { echo 'Core and managed release signers overlap.' >&2; exit 1; }
    devario_require_disjoint_fingerprint_sets core_fingerprints managed_fingerprints
  fi
  RECORD="$record" LOCK="$input_lock" CORE_ACTIVE="$core_active" CORE_PUBLIC="$core_public" \
  CORE_TRUSTED="$core_trusted" CORE_REVOKED="$core_revoked" CORE_ACTIVE_FILE="$core_active_file" \
  CORE_KEYRING="$core_keyring" MANAGED_ACTIVE="$managed_active" MANAGED_PUBLIC="$managed_public" \
  MANAGED_TRUSTED="$managed_trusted" MANAGED_REVOKED="$managed_revoked" \
  MANAGED_ACTIVE_FILE="$managed_active_file" MANAGED_KEYRING="$managed_keyring" ROOT_DIR="$root_dir" \
  EDITION="$edition" CORE_URL="$expected_core_url" MANAGED_URL="$expected_managed_url" \
  RELEASE_VERSION="$expected_release_version" \
  SCHEMA="$script_dir/schemas/image-build-record.schema.json" \
  LOCK_SCHEMA="$script_dir/schemas/core-input-lock.schema.json" python3 - <<'PY'
import hashlib,json,os,pathlib,shlex,stat
from jsonschema import Draft202012Validator
def hook(pairs):
 out={}
 for k,v in pairs:
  if k in out: raise SystemExit(f"duplicate JSON key: {k}")
  out[k]=v
 return out
record_path=pathlib.Path(os.environ["RECORD"]); lock_path=pathlib.Path(os.environ["LOCK"])
raw=record_path.read_bytes(); lock_raw=lock_path.read_bytes()
record=json.loads(raw,object_pairs_hook=hook); lock=json.loads(lock_raw,object_pairs_hook=hook)
canonical=lambda x:(json.dumps(x,sort_keys=True,separators=(",",":"))+"\n").encode()
if raw!=canonical(record) or lock_raw!=canonical(lock): raise SystemExit("release evidence JSON is not canonical")
Draft202012Validator(json.loads(pathlib.Path(os.environ["SCHEMA"]).read_text(),object_pairs_hook=hook)).validate(record)
Draft202012Validator(json.loads(pathlib.Path(os.environ["LOCK_SCHEMA"]).read_text(),object_pairs_hook=hook)).validate(lock)
if record["releaseMode"] is not True or record["edition"]!=os.environ["EDITION"]: raise SystemExit("embedded image is not the expected release edition")
if lock["operation"]!="iso" or lock["edition"]["id"]!=os.environ["EDITION"]: raise SystemExit("input lock is not for this ISO edition")
if lock["releaseVersion"]!=os.environ["RELEASE_VERSION"] or record["releaseVersion"]!=lock["releaseVersion"]: raise SystemExit("image/candidate release version differs from input lock")
if record["inputLockSha256"]!=hashlib.sha256(lock_raw).hexdigest(): raise SystemExit("embedded image does not bind the supplied input lock")
if record["coreCommit"]!=lock["core"]["commit"] or record["sourceDateEpoch"]!=lock["sourceDateEpoch"]: raise SystemExit("embedded source identity differs from lock")
if record["isoBuilder"] != lock["isoBuilder"]: raise SystemExit("image builder identity differs from lock")
root=pathlib.Path(os.environ["ROOT_DIR"])
os_release=root/"etc/os-release"
if not os_release.is_file() or os_release.is_symlink(): raise SystemExit("release image lacks a safe os-release identity")
identity={}
for number,line in enumerate(os_release.read_text(encoding="utf-8").splitlines(),1):
 if not line or line.startswith("#") or "=" not in line: raise SystemExit(f"unsupported os-release line {number}")
 key,value=line.split("=",1)
 if key in identity: raise SystemExit(f"duplicate os-release key: {key}")
 try: parsed=shlex.split(value,comments=False,posix=True)
 except ValueError as error: raise SystemExit(f"invalid os-release value at line {number}: {error}")
 if len(parsed)!=1: raise SystemExit(f"invalid os-release value at line {number}")
 identity[key]=parsed[0]
version=lock["releaseVersion"]; expected_name="Devario "+os.environ["EDITION"].title()
expected_identity={"NAME":expected_name,"PRETTY_NAME":expected_name+" "+version,"VERSION":version,"VERSION_ID":version,"BUILD_ID":version,"VARIANT_ID":os.environ["EDITION"]}
for key,value in expected_identity.items():
 if identity.get(key)!=value: raise SystemExit(f"installed os-release {key} differs from locked release identity")
if "development" in identity["PRETTY_NAME"].lower(): raise SystemExit("release image still identifies as Development")
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def closure(path,name):
 path=path.resolve(strict=True); files=[]
 for directory,dirnames,filenames in os.walk(path,followlinks=False):
  dirnames.sort(); filenames.sort()
  for entry in list(dirnames):
   candidate=pathlib.Path(directory)/entry
   if candidate.is_symlink(): dirnames.remove(entry); filenames.append(entry)
  for entry in sorted(filenames):
   candidate=pathlib.Path(directory)/entry; relative=candidate.relative_to(path).as_posix(); mode=candidate.lstat().st_mode
   if stat.S_ISLNK(mode): raise SystemExit(f"release keyring closure contains a symlink: {relative}")
   if not stat.S_ISREG(mode): raise SystemExit(f"release keyring closure contains a special file: {relative}")
   files.append({"path":relative,"mode":"100755" if mode&0o111 else "100644","size":candidate.stat().st_size,"sha256":sha(candidate)})
 return {"name":name,"files":files}
def check(name,prefix,active,public,trusted,revoked,active_file,keyring,url):
 value=record[name]
 if value!={"activeSigner":active,"publicKeyringSha256":sha(pathlib.Path(public)),"url":url}: raise SystemExit(f"embedded {name} trust differs from release evidence")
 expected_closure=closure(pathlib.Path(keyring),prefix)
 matches=[item for item in lock["keyrings"] if item["name"]==prefix]
 if matches != [expected_closure]: raise SystemExit(f"input lock does not bind exact {name} keyring closure")
 installed=root/f"usr/share/pacman/keyrings/{prefix}.gpg"
 installed_trusted=root/f"usr/share/pacman/keyrings/{prefix}-trusted"
 installed_revoked=root/f"usr/share/pacman/keyrings/{prefix}-revoked"
 installed_active=root/f"usr/share/devario/keyrings/{prefix}-active-signer"
 for supplied,embedded,label in ((pathlib.Path(public),installed,"public keys"),(pathlib.Path(trusted),installed_trusted,"trusted keys"),(pathlib.Path(revoked),installed_revoked,"revoked keys"),(pathlib.Path(active_file),installed_active,"active signer")):
  if supplied.read_bytes()!=embedded.read_bytes(): raise SystemExit(f"installed {name} {label} differ")
check("coreRepository","devario-core",os.environ["CORE_ACTIVE"],os.environ["CORE_PUBLIC"],os.environ["CORE_TRUSTED"],os.environ["CORE_REVOKED"],os.environ["CORE_ACTIVE_FILE"],os.environ["CORE_KEYRING"],os.environ["CORE_URL"])
if os.environ["EDITION"]=="managed": check("managedRepository","devario-managed",os.environ["MANAGED_ACTIVE"],os.environ["MANAGED_PUBLIC"],os.environ["MANAGED_TRUSTED"],os.environ["MANAGED_REVOKED"],os.environ["MANAGED_ACTIVE_FILE"],os.environ["MANAGED_KEYRING"],os.environ["MANAGED_URL"])
elif "managedRepository" in record: raise SystemExit("Community release record contains managed trust")
PY
fi
rm -f -- "$canonical_inventory"

echo "Image boundary verified for $edition."
