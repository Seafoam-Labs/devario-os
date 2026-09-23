#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; project_dir="$(cd -- "$script_dir/.." && pwd)"
# shellcheck source=lib/edition.sh
source "$script_dir/lib/edition.sh"
edition_dir=''; release_version=''
while (( $# )); do
  case "$1" in
    --edition) (( $# >= 2 )) || exit 2; edition_dir="$2"; shift 2 ;;
    --release-version) (( $# >= 2 )) || exit 2; release_version="$2"; shift 2 ;;
    -h|--help) echo 'Usage: build-iso-controlled-nspawn.sh --edition DIR --release-version VERSION'; exit 0 ;;
    *) echo "Unknown controlled ISO option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$edition_dir" && -n "$release_version" ]] || { echo 'Controlled ISO builder requires --edition and --release-version.' >&2; exit 2; }
devario_validate_release_version "$release_version"
(( EUID == 0 )) || { echo 'Controlled ISO builder must run through sudo.' >&2; exit 1; }
python3 -c 'import jsonschema' >/dev/null 2>&1 || { echo 'Host python-jsonschema is required.' >&2; exit 1; }
edition_dir="$(realpath -e -- "$edition_dir")"
container_root="${DEVARIO_NSPAWN_ROOT:-/var/lib/machines/devario-iso-builder}"
bootstrap_url="${DEVARIO_BOOTSTRAP_URL:-}"; repository_snapshot_url="${DEVARIO_REPOSITORY_SNAPSHOT_URL:-}"
bootstrap_cache="${DEVARIO_BOOTSTRAP_CACHE:-/var/cache/devario/bootstrap}"
bootstrap_keyring="${DEVARIO_BOOTSTRAP_KEYRING:-$project_dir/packages/devario-keyring/devario.gpg}"
core_repo="${DEVARIO_CORE_REPO_DIR:-}"; core_keyring="${DEVARIO_CORE_KEYRING_DIR:-$project_dir/packages/devario-keyring}"
seafoam_repo="${DEVARIO_SEAFOAM_REPO_DIR:-$project_dir/repo/seafoam}"
seafoam_keyring="${DEVARIO_SEAFOAM_KEYRING_DIR:-$project_dir/packages/seafoam-keyring}"
seafoam_url="${DEVARIO_SEAFOAM_REPO_URL:-https://repo.seafoam-labs.org/x86_64}"
managed_repo="${DEVARIO_MANAGED_REPO_DIR:-}"; managed_keyring="${DEVARIO_MANAGED_KEYRING_DIR:-}"
managed_input_lock="${DEVARIO_MANAGED_INPUT_LOCK:-}"
core_url="${DEVARIO_CORE_REPO_URL:-https://repo.seafoam-labs.org/devario-core/x86_64}"; managed_url="${DEVARIO_MANAGED_REPO_URL:-}"
signing_home="${DEVARIO_GNUPGHOME:-}"; signing_key="${DEVARIO_SIGNING_KEY:-}"
output_dir="$(realpath -m -- "${DEVARIO_OUTPUT_DIR:-$project_dir/out}")"
for value in "$bootstrap_url" "$repository_snapshot_url" "$core_repo" "$core_url" "$signing_home" "$signing_key"; do
  [[ -n "$value" ]] || { echo 'Controlled ISO builder is missing an immutable bootstrap/snapshot, core repository/URL, or signing input.' >&2; exit 1; }
done
devario_validate_https_url "$bootstrap_url"
[[ "$bootstrap_url" != */latest && "$bootstrap_url" != */latest/* ]] || { echo 'Bootstrap URL is mutable.' >&2; exit 1; }
[[ "$repository_snapshot_url" =~ ^https://[a-z0-9.-]+(:[0-9]{1,5})?/snapshots/[A-Za-z0-9._-]+/$ ]] || { echo 'Repository snapshot URL is not an exact date.' >&2; exit 1; }
for path in "$core_repo" "$core_keyring" "$seafoam_repo" "$seafoam_keyring"; do [[ -d "$path" && ! -L "$path" ]] || { echo "Unsafe core input: $path" >&2; exit 1; }; done
if [[ -e "$output_dir" ]] && [[ -n "$(find "$output_dir" -mindepth 1 -print -quit)" ]]; then echo 'ISO output must be fresh and empty.' >&2; exit 1; fi
if [[ -d "$container_root" ]] && [[ -n "$(find "$container_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then echo 'ISO builder root must be fresh and empty.' >&2; exit 1; fi
install -d -m 0755 "$output_dir"

composition_probe="$(mktemp -d /tmp/devario-edition-probe.XXXXXX)"
devario_compose_profile "$project_dir/iso" "$edition_dir" "$composition_probe" "$project_dir"
has_managed="$DEVARIO_EDITION_HAS_MANAGED"; edition_id="$DEVARIO_EDITION_ID"
rm -rf -- "$composition_probe"
if (( has_managed )); then
  for value in "$managed_repo" "$managed_keyring" "$managed_url" "$managed_input_lock"; do [[ -n "$value" ]] || { echo 'Managed ISO lacks separate managed repo/keyring/URL/input lock.' >&2; exit 1; }; done
  managed_input_lock="$(realpath -e -- "$managed_input_lock")"; [[ -f "$managed_input_lock" && ! -L "$managed_input_lock" ]] || exit 1
else
  [[ -z "$managed_repo" && -z "$managed_keyring" && -z "$managed_url" ]] || { echo 'Community ISO rejects managed inputs.' >&2; exit 1; }
fi
devario_verify_repository "$core_repo" devario-core "$core_keyring" production; core_active="$DEVARIO_ACTIVE_SIGNER"; core_fingerprints=("${DEVARIO_PUBLIC_FINGERPRINTS[@]}")
devario_verify_repository "$seafoam_repo" seafoam-labs "$seafoam_keyring" production
seafoam_fingerprints=("${DEVARIO_PUBLIC_FINGERPRINTS[@]}")
if (( has_managed )); then
  devario_verify_repository "$managed_repo" devario-managed "$managed_keyring" production
  managed_fingerprints=("${DEVARIO_PUBLIC_FINGERPRINTS[@]}")
  [[ "$core_active" != "$DEVARIO_ACTIVE_SIGNER" ]] || { echo 'Core/managed signer overlap.' >&2; exit 1; }
  devario_require_disjoint_fingerprint_sets core_fingerprints managed_fingerprints
  devario_require_disjoint_fingerprint_sets seafoam_fingerprints managed_fingerprints
fi
devario_validate_https_url "$seafoam_url"
devario_validate_https_url "$core_url"; if (( has_managed )); then devario_validate_https_url "$managed_url"; fi
signing_home="$(realpath -e -- "$signing_home")"; invoking_uid="${SUDO_UID:-}"
[[ "$invoking_uid" =~ ^[0-9]+$ && "$invoking_uid" != 0 && "$(stat -c '%u' "$signing_home")" == "$invoking_uid" && "$(stat -c '%a' "$signing_home")" == 700 ]] || { echo 'Core signing home must be invoking-user-owned mode 0700.' >&2; exit 1; }
for root in "$project_dir" "$edition_dir" "$core_repo" "$output_dir" "$container_root"; do root="$(realpath -m -- "$root")"; [[ "$signing_home" != "$root" && "$signing_home" != "$root/"* ]] || { echo 'Signing home overlaps a controlled root.' >&2; exit 1; }; done
devario_validate_keyring_bundle "$core_keyring" devario-core production; devario_require_active_secret_signer "$signing_home" "$signing_key"; signing_key="$DEVARIO_SIGNING_FINGERPRINT"

DEVARIO_RELEASE_BUILD=1 DEVARIO_SHELLY_BOOTSTRAP_REPO="$core_repo" DEVARIO_BOOTSTRAP_KEYRING_DIR="$core_keyring" \
DEVARIO_BOOTSTRAP_URL="$bootstrap_url" DEVARIO_REPOSITORY_SNAPSHOT_URL="$repository_snapshot_url" DEVARIO_NSPAWN_ROOT="$container_root" \
DEVARIO_BOOTSTRAP_CACHE="$bootstrap_cache" DEVARIO_BOOTSTRAP_KEYRING="$bootstrap_keyring" "$script_dir/build-packages-nspawn.sh" --prepare-only
run_root() { systemd-nspawn --quiet --register=no --console=pipe --resolv-conf=replace-host --directory="$container_root" "$@"; }
run_root /usr/bin/shelly sync standard --no-confirm
run_root /usr/bin/shelly install standard --no-confirm python libisoburn dosfstools mtools squashfs-tools openssl util-linux coreutils limine squashfs-tools libarchive
snapshot_id="${repository_snapshot_url##*/snapshots/}"; snapshot_id="${snapshot_id%/}"; snapshot_id="${snapshot_id//\//-}"
snapshot_dir="$bootstrap_cache/repository-snapshot-$snapshot_id"
for name in devario-core seafoam-labs; do cmp -s "$snapshot_dir/$name.db" "$container_root/var/lib/shelly/sync/$name.db" || { echo "ISO builder $name DB drifted." >&2; exit 1; }; done

temp="$(mktemp -d /tmp/devario-iso-nspawn.XXXXXX)"; container_work=''
cleanup(){ if [[ -n "$container_work" && "$container_work" == /var/tmp/devario-iso.* ]]; then run_root /usr/bin/rm -rf -- "$container_work" >/dev/null 2>&1 || true; fi; rm -rf -- "$temp"; }; trap cleanup EXIT
if (( has_managed )); then
  install -m 0444 "$managed_input_lock" "$temp/MANAGED-INPUT-LOCK.json"
  managed_input_lock="$temp/MANAGED-INPUT-LOCK.json"
fi
core_archive="$temp/core.tar"; core_report="$temp/core.json"; "$script_dir/verify-repository-boundary.sh" --repository "$project_dir" --archive "$core_archive" --report "$core_report"
core_commit="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' "$core_report")"; epoch="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sourceDateEpoch"])' "$core_report")"
core_snapshot="$temp/core"; install -d -m 0755 "$core_snapshot"; bsdtar -xf "$core_archive" -C "$core_snapshot"
if [[ "$edition_dir" == "$project_dir/editions/"* ]]; then edition_snapshot="$core_snapshot/${edition_dir#"$project_dir/"}"; edition_lock_dir="$edition_dir"; edition_commit=''; else
  edition_archive="$temp/edition.tar"; edition_report="$temp/edition.json"; "$script_dir/verify-repository-boundary.sh" --repository "$edition_dir" --archive "$edition_archive" --report "$edition_report"
  edition_snapshot="$temp/edition"; install -d -m 0755 "$edition_snapshot"; bsdtar -xf "$edition_archive" -C "$edition_snapshot"; edition_lock_dir="$edition_dir"; edition_commit="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' "$edition_report")"
fi
dependency="$temp/dependency.json"; CONTAINER_ROOT="$container_root" python3 - > "$dependency" <<'PY'
import json,os,pathlib
r=[]
for p in sorted((pathlib.Path(os.environ["CONTAINER_ROOT"])/"var/lib/shelly/local").glob("*/desc")):
 l=p.read_text().splitlines();f={};i=0
 while i<len(l):
  if l[i].startswith("%") and l[i].endswith("%") and i+1<len(l):f[l[i][1:-1]]=l[i+1];i+=2
  else:i+=1
 if not all(f.get(k) for k in ("NAME","VERSION","ARCH")):raise SystemExit("bad builder package record")
 r.append({"name":f["NAME"],"version":f["VERSION"],"architecture":f["ARCH"]})
r.sort(key=lambda x:x["name"]);print(json.dumps(r,sort_keys=True,separators=(",",":")))
PY
bootstrap="$bootstrap_cache/devario-bootstrap-x86_64.tar.zst"; mapfile -t shelly < <(find "$core_repo" -maxdepth 1 -type f -name 'shelly-[0-9]*.pkg.tar.zst' -print | sort -V); (( ${#shelly[@]}==1 )) || exit 1
manifest="$container_root/etc/devario/controlled-builder.json"; install -d -m 0755 "$(dirname -- "$manifest")"
root_digest="$($script_dir/tree-closure-digest.py --root "$container_root" --exclude dev --exclude proc --exclude sys --exclude run --exclude tmp --exclude var/tmp --exclude input --exclude output --exclude signing --exclude etc/resolv.conf --exclude etc/devario/controlled-builder.json --exclude etc/devario/controlled-builder.json.sig)"
"$script_dir/write-controlled-builder-manifest.py" --root-tree-sha256 "$root_digest" --repository-snapshot-url "$repository_snapshot_url" --repository-snapshot-dir "$snapshot_dir" \
 --bootstrap-archive "$bootstrap" --bootstrap-signature "$bootstrap.sig" --bootstrap-url "$bootstrap_url" --shelly-bootstrap "${shelly[0]}" --shelly-bootstrap-signature "${shelly[0]}.sig" --dependency-closure "$dependency" --output "$manifest"
GNUPGHOME="$signing_home" gpg --batch --yes --detach-sign --local-user "$signing_key" --output "$manifest.sig" "$manifest"; chmod 0444 "$manifest" "$manifest.sig"
arch_binary="$temp/bootstrap.gpg"; cp -- "$bootstrap_keyring" "$arch_binary"
lock="$temp/CORE-INPUT-LOCK.json"; lock_args=(--operation iso --core "$project_dir" --edition "$edition_lock_dir" --release-version "$release_version" --bootstrap-archive "$bootstrap" --bootstrap-signature "$bootstrap.sig" --bootstrap-url "$bootstrap_url" --repository-snapshot-dir "$snapshot_dir" --repository-snapshot-url "$repository_snapshot_url" --bootstrap-keyring "$arch_binary" --shelly-bootstrap "${shelly[0]}" --shelly-bootstrap-signature "${shelly[0]}.sig" --builder-manifest "$manifest" --builder-manifest-signature "$manifest.sig" --builder-keyring "$core_keyring" --builder-repository devario-core --dependency-closure "$dependency" --source-date-epoch "$epoch" --core-repo "$core_repo" --core-keyring "$core_keyring" --seafoam-repo "$seafoam_repo" --seafoam-keyring "$seafoam_keyring")
if (( has_managed )); then lock_args+=(--managed-repo "$managed_repo" --managed-keyring "$managed_keyring" --managed-input-lock "$managed_input_lock"); fi
"$script_dir/create-core-input-lock.sh" "${lock_args[@]}" --output "$lock"

container_work="$(run_root /usr/bin/mktemp -d /var/tmp/devario-iso.XXXXXX)"; [[ "$container_work" == /var/tmp/devario-iso.* ]] || exit 1
nspawn=(--quiet --register=no --console=pipe --resolv-conf=replace-host --capability=CAP_SYS_ADMIN,CAP_MKNOD --directory="$container_root" --bind-ro="$core_snapshot:/input/devario-os" --bind-ro="$edition_snapshot:/input/edition" --bind-ro="$core_repo:/input/core-repo" --bind-ro="$core_keyring:/input/core-keyring" --bind-ro="$seafoam_repo:/input/seafoam-repo" --bind-ro="$seafoam_keyring:/input/seafoam-keyring" --bind-ro="$lock:/input/CORE-INPUT-LOCK.json" --bind-ro="$manifest:/run/devario-controlled-builder/manifest.json" --bind-ro="$manifest.sig:/run/devario-controlled-builder/manifest.json.sig" --bind="$output_dir:/output")
if (( has_managed )); then nspawn+=(--bind-ro="$managed_repo:/input/managed-repo" --bind-ro="$managed_keyring:/input/managed-keyring" --bind-ro="$managed_input_lock:/input/MANAGED-INPUT-LOCK.json"); fi
if [[ -n "${DEVARIO_EXPECTED_IMAGE_INVENTORY:-}" ]]; then nspawn+=(--bind-ro="$(realpath -e -- "$DEVARIO_EXPECTED_IMAGE_INVENTORY"):/input/EXPECTED-IMAGE-INVENTORY.json"); expected_env=(--setenv=DEVARIO_EXPECTED_IMAGE_INVENTORY=/input/EXPECTED-IMAGE-INVENTORY.json); else expected_env=(); fi
managed_env=(); if (( has_managed )); then managed_env=(--setenv=DEVARIO_MANAGED_REPO_DIR=/input/managed-repo --setenv=DEVARIO_MANAGED_KEYRING_DIR=/input/managed-keyring --setenv="DEVARIO_MANAGED_REPO_URL=$managed_url" --setenv="DEVARIO_MANAGED_COMMIT=$edition_commit"); fi
log="$temp/devario-iso-build.log"; set +e
systemd-nspawn "${nspawn[@]}" --chdir=/input/devario-os --setenv=DEVARIO_CONTROLLED_NSPAWN=1 --setenv=DEVARIO_EXPECTED_OPERATION=iso --setenv=DEVARIO_INPUT_LOCK=/input/CORE-INPUT-LOCK.json --setenv=DEVARIO_CORE_REPO_DIR=/input/core-repo --setenv=DEVARIO_CORE_KEYRING_DIR=/input/core-keyring --setenv=DEVARIO_SEAFOAM_REPO_DIR=/input/seafoam-repo --setenv=DEVARIO_SEAFOAM_KEYRING_DIR=/input/seafoam-keyring --setenv="DEVARIO_SEAFOAM_REPO_URL=$seafoam_url" --setenv="DEVARIO_CORE_REPO_URL=$core_url" --setenv=DEVARIO_KEYRING_DIR=/input/core-keyring --setenv=DEVARIO_REPOSITORY_NAME=devario-core --setenv=DEVARIO_RELEASE_BUILD=1 --setenv="DEVARIO_RELEASE_VERSION=$release_version" --setenv=DEVARIO_VERIFIED_SOURCE=1 --setenv="DEVARIO_CORE_COMMIT=$core_commit" --setenv="SOURCE_DATE_EPOCH=$epoch" --setenv=DEVARIO_OUTPUT_DIR=/output --setenv="DEVARIO_WORK_DIR=$container_work" "${managed_env[@]}" "${expected_env[@]}" /usr/bin/env -u LD_PRELOAD ./scripts/build-iso.sh --edition /input/edition >"$log" 2>&1
status=$?; set -e
install -m 0444 "$log" "$output_dir/devario-iso-build.log"; (( status==0 )) || { tail -n 200 "$log" >&2; exit "$status"; }
install -m 0444 "$lock" "$output_dir/CORE-INPUT-LOCK.json"
install -m 0444 "$manifest" "$output_dir/CONTROLLED-BUILDER.json"
install -m 0444 "$manifest.sig" "$output_dir/CONTROLLED-BUILDER.json.sig"
attestation_managed=(); if (( has_managed )); then
  install -m 0444 "$managed_input_lock" "$output_dir/MANAGED-INPUT-LOCK.json"
  attestation_managed=(--managed-input-lock "$output_dir/MANAGED-INPUT-LOCK.json")
fi
"$script_dir/write-builder-attestation.sh" --input-lock "$lock" --output-tree "$output_dir" --builder-marker "$manifest" --builder-packages "$dependency" --operation iso "${attestation_managed[@]}" --keyring-dir "$core_keyring" --repository-name devario-core --signing-home "$signing_home" --signing-key "$signing_key" --output "$output_dir/BUILDER-ATTESTATION.json"
printf '%s\n' "consumed ISO build $core_commit $edition_id" > "$container_root/.devario-controlled-builder-consumed"; chmod 0444 "$container_root/.devario-controlled-builder-consumed"
echo "Controlled ISO output: $output_dir"
