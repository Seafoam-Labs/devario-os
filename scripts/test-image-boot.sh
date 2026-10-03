#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; project_dir="$(cd -- "$script_dir/.." && pwd)"
# shellcheck source=../release/lib-release.sh
source "$project_dir/release/lib-release.sh"
image='' source_image='' installation_lock='' disk_format='' candidate='' mode='' firmware='' edition='' log='' result='' timeout_seconds=300
while (( $# )); do
  case "$1" in
    --image|--disk) image="$2"; shift 2 ;;
    --disk-format) disk_format="$2"; shift 2 ;;
    --source-image) source_image="$2"; shift 2 ;;
    --installation-lock) installation_lock="$2"; shift 2 ;;
    --candidate) candidate="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --firmware) firmware="$2"; shift 2 ;;
    --edition) edition="$2"; shift 2 ;;
    --log) log="$2"; shift 2 ;;
    --result) result="$2"; shift 2 ;;
    --timeout) timeout_seconds="$2"; shift 2 ;;
    *) echo 'Usage: test-image-boot.sh (--image ISO|--disk DISK --disk-format raw|qcow2 --source-image ISO --installation-lock FILE) --candidate LOCK --mode live|installed --firmware bios|uefi --edition community|managed --log FILE --result FILE [--timeout SEC]' >&2; exit 2 ;;
  esac
done
for value in image candidate mode firmware edition log result; do [[ -n "${!value}" ]] || { echo "Missing $value." >&2; exit 2; }; done
[[ -f "$image" && ! -L "$image" && -f "$candidate" ]] || { echo 'Image and candidate must be regular files.' >&2; exit 1; }
[[ "$mode" == live || "$mode" == installed ]] || exit 2
[[ "$firmware" == bios || "$firmware" == uefi ]] || exit 2
[[ "$mode" != installed || "$firmware" == uefi ]] || { echo "Installed Devario requires UEFI." >&2; exit 2; }
[[ "$edition" == community || "$edition" == managed ]] || exit 2
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || exit 2
python3 "$project_dir/release/validate-json.py" "$project_dir/release/candidate-lock.schema.json" "$candidate"
[[ "$(jq -r '.edition' "$candidate")" == "$edition" ]] || { echo 'Candidate edition mismatch.' >&2; exit 1; }
candidate_has_artifact() {
  devario_candidate_artifact_path "$candidate" "$1" >/dev/null
}
[[ ! -e "$log" && ! -e "$result" ]] || { echo 'Log/result output already exists.' >&2; exit 1; }
mkdir -p -- "$(dirname -- "$log")" "$(dirname -- "$result")"

qemu=(qemu-system-x86_64 -machine q35,accel=tcg -cpu max -m 3072 -smp 2 -display none -serial stdio -monitor none -no-reboot -fw_cfg "name=opt/org.devario/acceptance,string=mode=$mode firmware=$firmware edition=$edition")
if [[ "$firmware" == uefi ]]; then
  ovmf="${DEVARIO_OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.fd}"
  [[ -f "$ovmf" ]] || { echo "UEFI firmware is missing: $ovmf" >&2; exit 1; }
  qemu+=(-drive "if=pflash,format=raw,readonly=on,file=$ovmf")
fi
if [[ "$mode" == live ]]; then
  [[ -z "$disk_format" ]] || { echo 'Live acceptance does not use --disk-format.' >&2; exit 2; }
  [[ -z "$source_image" && -z "$installation_lock" ]] || { echo 'Live acceptance rejects installed-disk evidence options.' >&2; exit 2; }
  candidate_has_artifact "$image" || { echo 'Live image is not an exact candidate artifact.' >&2; exit 1; }
  qemu+=(-boot d -cdrom "$image")
else
  [[ "$disk_format" == raw || "$disk_format" == qcow2 ]] || { echo 'Installed acceptance requires --disk-format raw|qcow2.' >&2; exit 2; }
  [[ -f "$source_image" && -f "$installation_lock" ]] || { echo 'Installed acceptance requires its candidate source image and canonical installation lock.' >&2; exit 2; }
  candidate_has_artifact "$source_image" || { echo 'Installed source image is not an exact candidate artifact.' >&2; exit 1; }
  bash "$project_dir/release/validate-installation-lock.sh" --lock "$installation_lock" --candidate "$candidate" --source-image "$source_image" --disk "$image"
  if [[ "$disk_format" == qcow2 ]]; then
    qemu-img info --output=json "$image" | jq -e '(."backing-filename" // null) == null and (."data-file" // null) == null' >/dev/null || { echo 'Installed qcow2 must be self-contained.' >&2; exit 1; }
  fi
  qemu+=(-boot c -drive "file=$image,format=$disk_format,if=virtio,cache=none")
fi

set +e
timeout --signal=TERM --kill-after=10 "$timeout_seconds" "${qemu[@]}" > "$log" 2>&1
qemu_status=$?
set -e
normalized="$(mktemp /tmp/devario-acceptance-log.XXXXXX)"; trap 'rm -f -- "$normalized"' EXIT
sed $'s/\r$//; s/\033\[[0-9;]*[[:alpha:]]//g' "$log" > "$normalized"
expected="DEVARIO_ACCEPTANCE:PASS mode=$mode firmware=$firmware edition=$edition"
marker_count="$(grep -Ec '^DEVARIO_ACCEPTANCE:(PASS|FAIL)' "$normalized" || true)"
expected_count="$(grep -Fxc "$expected" "$normalized" || true)"
if [[ "$marker_count" != 1 || "$expected_count" != 1 ]]; then
  echo "QEMU acceptance did not emit exactly one expected marker (status $qemu_status)." >&2; exit 1
fi
candidate_sha="$(sha256sum "$candidate")"; candidate_sha="${candidate_sha%% *}"
image_sha="$(sha256sum "$image")"; image_sha="${image_sha%% *}"; image_size="$(stat -c '%s' "$image")"
log_sha="$(sha256sum "$log")"; log_sha="${log_sha%% *}"; log_size="$(stat -c '%s' "$log")"
temporary="$(mktemp /tmp/devario-acceptance-result.XXXXXX)"; trap 'rm -f -- "$normalized" "$temporary"' EXIT
jq -n --arg candidate "$candidate_sha" --arg candidateVersion "$(jq -r '.version' "$candidate")" --arg edition "$edition" --arg mode "$mode" --arg firmware "$firmware" \
  --arg imageName "$(basename -- "$image")" --arg imageSha "$image_sha" --argjson imageSize "$image_size" \
  --arg logName "$(basename -- "$log")" --arg logSha "$log_sha" --argjson logSize "$log_size" --arg marker "$expected" '
  {schemaVersion:1,candidateSha256:$candidate,candidateVersion:$candidateVersion,edition:$edition,mode:$mode,firmware:$firmware,
   image:{name:$imageName,sha256:$imageSha,size:$imageSize},log:{name:$logName,sha256:$logSha,size:$logSize},marker:$marker,outcome:"pass"}' > "$temporary"
python3 "$project_dir/release/validate-json.py" "$project_dir/release/image-acceptance.schema.json" "$temporary"
install -m 0444 "$temporary" "$result"; chmod 0444 "$log"
echo "Accepted exact $mode/$firmware candidate image."
