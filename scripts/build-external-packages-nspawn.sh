#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
# shellcheck source=lib/repository.sh
source "$script_dir/lib/repository.sh"

overlay_dir=''; input_root=''; output_dir=''
container_root="${DEVARIO_NSPAWN_ROOT:-/var/lib/machines/devario-managed-builder}"
signing_home="${DEVARIO_GNUPGHOME:-}"; signing_key="${DEVARIO_SIGNING_KEY:-}"
bootstrap_url="${DEVARIO_BOOTSTRAP_URL:-}"
bootstrap_cache="${DEVARIO_BOOTSTRAP_CACHE:-/var/cache/devario/bootstrap}"
repository_snapshot_url="${DEVARIO_REPOSITORY_SNAPSHOT_URL:-}"
bootstrap_keyring="${DEVARIO_BOOTSTRAP_KEYRING:-$project_dir/packages/devario-keyring/devario.gpg}"
container_user=devario-build

usage() {
  cat <<'EOF'
Usage: build-packages-nspawn.sh --managed-build --managed-overlay DIR \
  --managed-input-root DIR --output DIR

The managed input root must contain devario-core/, core-keyring/, and
managed-keyring/. The wrapper requires a fresh container root, immutable Arch
bootstrap/snapshot URLs, an external mode-0700 managed signing home, exact
clean Git archives, and produces a signed closed output containing
CORE-INPUT-LOCK.json and BUILDER-ATTESTATION.json.
EOF
}
while (( $# )); do
  case "$1" in
    --managed-overlay) overlay_dir="$2"; shift 2 ;;
    --managed-input-root) input_root="$2"; shift 2 ;;
    --output) output_dir="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown managed-build option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$overlay_dir" && -n "$input_root" && -n "$output_dir" ]] || { usage >&2; exit 2; }
(( EUID == 0 )) || { echo 'The controlled wrapper must run through sudo.' >&2; exit 1; }
for command_name in bsdtar cmp find gpg install python3 realpath stat systemd-nspawn; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "Missing host command: $command_name" >&2; exit 1; }
done
# shellcheck source=lib/python-env.sh
source "$script_dir/lib/python-env.sh"
devario_use_validation_python

overlay_dir="$(realpath -e -- "$overlay_dir")"; input_root="$(realpath -e -- "$input_root")"
output_dir="$(realpath -m -- "$output_dir")"
build_uid="$(stat -c '%u' "$overlay_dir")"; build_gid="$(stat -c '%g' "$overlay_dir")"
locked_core=''; line_count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  (( line_count += 1 ))
  [[ "$line" =~ ^devario_os_commit=([0-9a-f]{40})$ ]] || { echo 'Managed base.lock is invalid.' >&2; exit 1; }
  locked_core="${BASH_REMATCH[1]}"
done < "$overlay_dir/base.lock"
core_head="$(git -C "$project_dir" rev-parse --verify 'HEAD^{commit}')"
if (( line_count != 1 )) || [[ "$locked_core" != "$core_head" ]]; then
  echo "Managed base.lock does not pin exact core HEAD $core_head." >&2; exit 1
fi
core_repo="$input_root/devario-core"; core_keyring="$input_root/core-keyring"; managed_keyring="$input_root/managed-keyring"
for path in "$core_repo" "$core_keyring" "$managed_keyring"; do
  [[ -d "$path" && ! -L "$path" ]] || { echo "Missing closed managed input: $path" >&2; exit 1; }
done
if [[ -e "$output_dir" ]] && [[ -n "$(find "$output_dir" -mindepth 1 -print -quit)" ]]; then
  echo "Managed output must be fresh and empty: $output_dir" >&2; exit 1
fi
if [[ -d "$container_root" ]] && [[ -n "$(find "$container_root" -mindepth 1 -print -quit)" ]]; then
  echo 'Managed release requires a fresh, empty DEVARIO_NSPAWN_ROOT.' >&2; exit 1
fi
devario_validate_https_url "$bootstrap_url"
[[ "$bootstrap_url" != */latest && "$bootstrap_url" != */latest/* ]] || {
  echo 'Managed release requires an immutable DEVARIO_BOOTSTRAP_URL.' >&2; exit 1;
}
[[ "$repository_snapshot_url" =~ ^https://[a-z0-9.-]+(:[0-9]{1,5})?/snapshots/[A-Za-z0-9._-]+/$ ]] || {
  echo 'Managed release requires an exact dated DEVARIO_REPOSITORY_SNAPSHOT_URL.' >&2; exit 1;
}
devario_verify_repository "$core_repo" devario-core "$core_keyring" production
core_active="$DEVARIO_ACTIVE_SIGNER"
core_fingerprints=("${DEVARIO_PUBLIC_FINGERPRINTS[@]}")
devario_validate_keyring_bundle "$managed_keyring" devario-managed production
managed_active="$DEVARIO_ACTIVE_SIGNER"
managed_fingerprints=("${DEVARIO_PUBLIC_FINGERPRINTS[@]}")
[[ "$core_active" != "$managed_active" ]] || { echo 'Core and managed active fingerprints must be distinct.' >&2; exit 1; }
devario_require_disjoint_fingerprint_sets core_fingerprints managed_fingerprints
if [[ -z "$signing_home" || -z "$signing_key" ]]; then
  echo 'Managed release requires an explicit external signing home and active key.' >&2; exit 1
fi
signing_home="$(realpath -e -- "$signing_home")"
invoking_uid="${SUDO_UID:-}"
[[ "$invoking_uid" =~ ^[0-9]+$ && "$invoking_uid" != 0 ]] || { echo 'Could not authenticate the invoking build user.' >&2; exit 1; }
[[ "$build_uid" == "$invoking_uid" ]] || { echo 'Managed overlay must be owned by the invoking build user.' >&2; exit 1; }
[[ "$(stat -c '%u' "$signing_home")" == "$invoking_uid" && "$(stat -c '%a' "$signing_home")" == 700 ]] || {
  echo 'Managed signing home must be owned by the invoking user and mode 0700.' >&2; exit 1;
}
for root in "$project_dir" "$overlay_dir" "$input_root" "$output_dir" "$container_root"; do
  root="$(realpath -m -- "$root")"
  [[ "$signing_home" != "$root" && "$signing_home" != "$root/"* ]] || {
    echo 'Managed signing home must be physically outside all source/input/output/builder roots.' >&2; exit 1;
  }
done
install -d -o "$build_uid" -g "$build_gid" -m 0755 "$output_dir"
devario_validate_keyring_bundle "$managed_keyring" devario-managed production
devario_require_active_secret_signer "$signing_home" "$signing_key"
signing_key="$DEVARIO_SIGNING_FINGERPRINT"

# Create the fresh signed-snapshot builder. Core Shelly is verified only by the
# core active signer before extraction.
DEVARIO_RELEASE_BUILD=1 \
DEVARIO_SHELLY_BOOTSTRAP_REPO="$core_repo" \
DEVARIO_BOOTSTRAP_KEYRING_DIR="$core_keyring" \
DEVARIO_BOOTSTRAP_URL="$bootstrap_url" \
DEVARIO_REPOSITORY_SNAPSHOT_URL="$repository_snapshot_url" \
DEVARIO_NSPAWN_ROOT="$container_root" \
DEVARIO_BOOTSTRAP_CACHE="$bootstrap_cache" \
DEVARIO_BOOTSTRAP_KEYRING="$bootstrap_keyring" \
  "$script_dir/build-packages-nspawn.sh" --prepare-only

temporary_dir="$(mktemp -d /tmp/devario-external-nspawn.XXXXXX)"; container_work=''
cleanup() {
  if [[ -n "$container_work" && "$container_work" == /var/tmp/devario-external.* ]]; then
    systemd-nspawn --quiet --register=no --console=pipe --directory="$container_root" \
      /usr/bin/rm -rf -- "$container_work" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$temporary_dir"
}
trap cleanup EXIT
core_archive="$temporary_dir/devario-os.tar"; core_report="$temporary_dir/devario-os.json"
overlay_archive="$temporary_dir/overlay.tar"; overlay_report="$temporary_dir/overlay.json"
"$script_dir/verify-repository-boundary.sh" --repository "$project_dir" --archive "$core_archive" --report "$core_report"
"$script_dir/verify-repository-boundary.sh" --repository "$overlay_dir" --archive "$overlay_archive" --report "$overlay_report"
core_commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$core_report")"
managed_commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$overlay_report")"
source_date_epoch="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceDateEpoch"])' "$core_report")"
[[ "$locked_core" == "$core_commit" ]] || { echo 'Managed base.lock changed across exact source export.' >&2; exit 1; }
core_snapshot="$temporary_dir/core"; overlay_snapshot="$temporary_dir/overlay"
install -d -m 0755 "$core_snapshot" "$overlay_snapshot"
bsdtar -xf "$core_archive" -C "$core_snapshot"; bsdtar -xf "$overlay_archive" -C "$overlay_snapshot"
[[ -x "$overlay_snapshot/scripts/build-packages.sh" ]] || { echo 'Managed build script is missing or not executable.' >&2; exit 1; }

base_nspawn=(--quiet --register=no --console=pipe --resolv-conf=replace-host --directory="$container_root"
  --bind-ro="$core_snapshot:/input/devario-os" --bind-ro="$overlay_snapshot:/input/devario-managed-overlay"
  --bind-ro="$core_repo:/input/devario-core-repo" --bind-ro="$core_keyring:/input/devario-core-keyring"
  --bind-ro="$managed_keyring:/input/devario-managed-keyring")
run_container() { systemd-nspawn "${base_nspawn[@]}" "$@"; }
# Managed scripts also run Python directly; use the prepared guest environment.
guest_validation_env="$(run_container /usr/bin/python3 -I -B \
  /input/devario-os/scripts/prepare-validation-env.py --cache-dir /opt/devario/validation-python --check)"
base_nspawn+=(--setenv="PATH=$guest_validation_env/bin:/usr/local/sbin:/usr/local/bin:/usr/bin" \
  --setenv=PYTHONDONTWRITEBYTECODE=1 --setenv=PYTHONNOUSERSITE=1)

container_work="$(run_container /usr/bin/mktemp -d /var/tmp/devario-external.XXXXXX)"
[[ "$container_work" == /var/tmp/devario-external.* ]] || { echo 'Unsafe builder work path.' >&2; exit 1; }
run_container /usr/bin/install -d -m 0755 "$container_work/overlay" "$container_work/package-work" "$container_work/repo" "$container_work/sources"
run_container /usr/bin/cp -a /input/devario-managed-overlay/. "$container_work/overlay/"
run_container /usr/bin/chown -R "$build_uid:$build_gid" "$container_work"
systemd-nspawn "${base_nspawn[@]}" --user="$container_user" --chdir="$container_work/overlay" \
  --setenv=DEVARIO_BUILDER_PREPARE=1 --setenv=DEVARIO_RELEASE_BUILD=1 --setenv=DEVARIO_VERIFIED_SOURCE=1 \
  --setenv=DEVARIO_CORE_DIR=/input/devario-os --setenv="DEVARIO_MANAGED_SOURCE_DIR=$container_work/overlay" \
  --setenv=DEVARIO_CORE_REPO_DIR=/input/devario-core-repo --setenv=DEVARIO_CORE_KEYRING_DIR=/input/devario-core-keyring \
  --setenv=DEVARIO_KEYRING_DIR=/input/devario-managed-keyring --setenv=DEVARIO_REPOSITORY_NAME=devario-managed \
  --setenv="DEVARIO_PACKAGE_OUTPUT_DIR=$container_work/repo" --setenv="DEVARIO_SOURCE_OUTPUT_DIR=$container_work/sources" \
  --setenv="DEVARIO_PACKAGE_WORK_DIR=$container_work/package-work" --setenv=DEVARIO_KEY_POLICY=production \
  --setenv="DEVARIO_CORE_COMMIT=$core_commit" --setenv="DEVARIO_MANAGED_COMMIT=$managed_commit" \
  --setenv="SOURCE_DATE_EPOCH=$source_date_epoch" --setenv=DEVARIO_GNUPGHOME=/signing \
  --setenv="DEVARIO_SIGNING_KEY=$signing_key" /usr/bin/env -u LD_PRELOAD ./scripts/build-packages.sh
run_container /usr/bin/rm -rf -- "$container_work"; container_work=''

dependency_closure="$temporary_dir/dependency-closure.json"
CONTAINER_ROOT="$container_root" python3 - > "$dependency_closure" <<'PY'
import json,os,pathlib
records=[]
for desc in sorted((pathlib.Path(os.environ["CONTAINER_ROOT"])/"var/lib/shelly/local").glob("*/desc")):
 lines=desc.read_text().splitlines(); fields={}; i=0
 while i<len(lines):
  if lines[i].startswith("%") and lines[i].endswith("%") and i+1<len(lines): fields[lines[i][1:-1]]=lines[i+1]; i+=2
  else:i+=1
 if not all(fields.get(k) for k in ("NAME","VERSION","ARCH")): raise SystemExit(f"bad local record {desc}")
 records.append({"name":fields["NAME"],"version":fields["VERSION"],"architecture":fields["ARCH"]})
records.sort(key=lambda x:x["name"])
if not records or len(records)!=len({x["name"] for x in records}): raise SystemExit("invalid dependency closure")
print(json.dumps(records,sort_keys=True,separators=(",",":")))
PY
snapshot_id="${repository_snapshot_url##*/snapshots/}"; snapshot_id="${snapshot_id%/}"; snapshot_id="${snapshot_id//\//-}"
repository_snapshot_dir="$bootstrap_cache/repository-snapshot-$snapshot_id"
bootstrap_archive="$bootstrap_cache/devario-bootstrap-x86_64.tar.zst"; bootstrap_signature="$bootstrap_archive.sig"
mapfile -t shelly_packages < <(find "$core_repo" -maxdepth 1 -type f -name 'shelly-cli-[0-9]*.pkg.tar.zst' -print | sort -V)
(( ${#shelly_packages[@]} == 1 )) || { echo 'Core input must contain exactly one Shelly bootstrap.' >&2; exit 1; }
shelly_package="${shelly_packages[0]}"; shelly_signature="$shelly_package.sig"
container_manifest="$container_root/etc/devario/controlled-builder.json"; install -d -m 0755 "$(dirname -- "$container_manifest")"
root_digest="$($script_dir/tree-closure-digest.py --root "$container_root" --exclude dev --exclude proc --exclude sys --exclude run --exclude tmp --exclude var/tmp --exclude input --exclude output --exclude signing --exclude etc/resolv.conf --exclude etc/devario/controlled-builder.json --exclude etc/devario/controlled-builder.json.sig)"
"$script_dir/write-controlled-builder-manifest.py" --root-tree-sha256 "$root_digest" \
  --repository-snapshot-url "$repository_snapshot_url" --repository-snapshot-dir "$repository_snapshot_dir" \
  --bootstrap-archive "$bootstrap_archive" --bootstrap-signature "$bootstrap_signature" --bootstrap-url "$bootstrap_url" \
  --shelly-bootstrap "$shelly_package" --shelly-bootstrap-signature "$shelly_signature" \
  --dependency-closure "$dependency_closure" --output "$container_manifest"
GNUPGHOME="$signing_home" gpg --batch --yes --detach-sign --local-user "$signing_key" --output "$container_manifest.sig" "$container_manifest"
chmod 0444 "$container_manifest" "$container_manifest.sig"
devario_validate_keyring_bundle "$managed_keyring" devario-managed production; devario_gpgv_active_signature "$container_manifest.sig" "$container_manifest"
normalized_bootstrap_keyring="$temporary_dir/bootstrap.gpg"; cp -- "$bootstrap_keyring" "$normalized_bootstrap_keyring"
input_lock="$temporary_dir/CORE-INPUT-LOCK.json"
"$script_dir/create-core-input-lock.sh" --operation external-packages --core "$project_dir" --edition "$overlay_dir" \
  --bootstrap-archive "$bootstrap_archive" --bootstrap-signature "$bootstrap_signature" --bootstrap-url "$bootstrap_url" \
  --repository-snapshot-dir "$repository_snapshot_dir" --repository-snapshot-url "$repository_snapshot_url" --bootstrap-keyring "$normalized_bootstrap_keyring" \
  --shelly-bootstrap "$shelly_package" --shelly-bootstrap-signature "$shelly_signature" \
  --builder-manifest "$container_manifest" --builder-manifest-signature "$container_manifest.sig" \
  --builder-keyring "$managed_keyring" --builder-repository devario-managed --dependency-closure "$dependency_closure" \
  --source-date-epoch "$source_date_epoch" --core-repo "$core_repo" --core-keyring "$core_keyring" \
  --managed-keyring "$managed_keyring" --output "$input_lock"
install -m 0444 "$input_lock" "$output_dir/CORE-INPUT-LOCK.json"

observed="$($script_dir/tree-closure-digest.py --root "$container_root" --exclude dev --exclude proc --exclude sys --exclude run --exclude tmp --exclude var/tmp --exclude input --exclude output --exclude signing --exclude etc/resolv.conf --exclude etc/devario/controlled-builder.json --exclude etc/devario/controlled-builder.json.sig)"
[[ "$observed" == "$root_digest" ]] || { echo 'Managed controlled builder changed before construction.' >&2; exit 1; }
base_nspawn+=(--bind-ro="$input_lock:/input/CORE-INPUT-LOCK.json" \
  --bind-ro="$container_manifest:/run/devario-controlled-builder/manifest.json" \
  --bind-ro="$container_manifest.sig:/run/devario-controlled-builder/manifest.json.sig" \
  --bind="$output_dir:/output" --bind="$signing_home:/signing")
container_work="$(run_container /usr/bin/mktemp -d /var/tmp/devario-external.XXXXXX)"
run_container /usr/bin/install -d -m 0755 "$container_work/overlay" "$container_work/package-work"
run_container /usr/bin/cp -a /input/devario-managed-overlay/. "$container_work/overlay/"; run_container /usr/bin/chown -R "$build_uid:$build_gid" "$container_work"
systemd-nspawn "${base_nspawn[@]}" --user="$container_user" --chdir="$container_work/overlay" \
  --setenv=DEVARIO_CONTROLLED_NSPAWN=1 --setenv=DEVARIO_EXPECTED_OPERATION=external-packages \
  --setenv=DEVARIO_INPUT_LOCK=/input/CORE-INPUT-LOCK.json --setenv=DEVARIO_CORE_DIR=/input/devario-os \
  --setenv="DEVARIO_MANAGED_SOURCE_DIR=$container_work/overlay" --setenv=DEVARIO_CORE_REPO_DIR=/input/devario-core-repo \
  --setenv=DEVARIO_CORE_KEYRING_DIR=/input/devario-core-keyring --setenv=DEVARIO_KEYRING_DIR=/input/devario-managed-keyring \
  --setenv=DEVARIO_PACKAGE_OUTPUT_DIR=/output/devario-managed --setenv=DEVARIO_SOURCE_OUTPUT_DIR=/output/sources \
  --setenv=DEVARIO_MANAGED_INPUT_LOCK_OUTPUT=/output/MANAGED-INPUT-LOCK.json \
  --setenv="DEVARIO_PACKAGE_WORK_DIR=$container_work/package-work" --setenv=DEVARIO_REPOSITORY_NAME=devario-managed \
  --setenv=DEVARIO_RELEASE_BUILD=1 --setenv=DEVARIO_VERIFIED_SOURCE=1 --setenv=DEVARIO_KEY_POLICY=production \
  --setenv="DEVARIO_CORE_COMMIT=$core_commit" --setenv="DEVARIO_MANAGED_COMMIT=$managed_commit" --setenv="SOURCE_DATE_EPOCH=$source_date_epoch" \
  --setenv=DEVARIO_GNUPGHOME=/signing --setenv="DEVARIO_SIGNING_KEY=$signing_key" /usr/bin/env -u LD_PRELOAD ./scripts/build-packages.sh
devario_verify_repository "$output_dir/devario-managed" devario-managed "$managed_keyring" production
[[ -f "$output_dir/MANAGED-INPUT-LOCK.json" && ! -L "$output_dir/MANAGED-INPUT-LOCK.json" ]] || { echo 'Managed build did not emit MANAGED-INPUT-LOCK.json.' >&2; exit 1; }
install -m 0444 "$container_manifest" "$output_dir/CONTROLLED-BUILDER.json"
install -m 0444 "$container_manifest.sig" "$output_dir/CONTROLLED-BUILDER.json.sig"
"$script_dir/write-builder-attestation.sh" --input-lock "$input_lock" --output-tree "$output_dir" \
  --builder-marker "$container_manifest" --builder-packages "$dependency_closure" --operation external-packages \
  --managed-input-lock "$output_dir/MANAGED-INPUT-LOCK.json" \
  --keyring-dir "$managed_keyring" --repository-name devario-managed --signing-home "$signing_home" --signing-key "$signing_key" \
  --output "$output_dir/BUILDER-ATTESTATION.json"
printf '%s\n' "consumed managed build $managed_commit" > "$container_root/.devario-controlled-builder-consumed"; chmod 0444 "$container_root/.devario-controlled-builder-consumed"
echo "Controlled managed package output: $output_dir"
