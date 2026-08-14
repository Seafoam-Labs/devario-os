#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; source "$script_dir/lib-release.sh"
review='' signature='' installation_lock='' candidate='' disk=''
policy="$script_dir/approval-trust-policy.json"; keyring="$script_dir/approval-keyring/release-approvers.gpg"
while (( $# )); do
  case "$1" in
    --review) review="$2"; shift 2;; --signature) signature="$2"; shift 2;;
    --installation-lock) installation_lock="$2"; shift 2;; --candidate) candidate="$2"; shift 2;; --disk) disk="$2"; shift 2;;
    --trust-policy) policy="$2"; shift 2;; --keyring) keyring="$2"; shift 2;; *) exit 2;;
  esac
done
for value in review signature installation_lock candidate disk; do [[ -n "${!value}" ]] || exit 2; done
python3 "$script_dir/validate-json.py" "$script_dir/installation-review.schema.json" "$review"
python3 "$script_dir/validate-json.py" "$script_dir/candidate-lock.schema.json" "$candidate"
python3 "$script_dir/validate-json.py" "$script_dir/installation-lock.schema.json" "$installation_lock"
bash "$script_dir/validate-trust-policy.sh" --policy "$policy" --keyring "$keyring" --purpose human-release-approval
active="$(jq -r '.activeFingerprint // empty' "$policy")"
[[ -n "$active" && "$(jq -r '.purpose' "$policy")" == human-release-approval ]] || { echo 'Fixed human approval trust is not provisioned.' >&2; exit 1; }
[[ "$(jq -r '.reviewerFingerprint' "$review")" == "$active" ]] || { echo 'Review fingerprint is not the currently active approver.' >&2; exit 1; }
candidate_sha="$(devario_sha256 "$candidate")"; disk_sha="$(devario_sha256 "$disk")"; edition="$(jq -r '.edition' "$candidate")"; candidate_version="$(jq -r '.version' "$candidate")"
jq -e --arg candidate "$candidate_sha" --arg candidateVersion "$candidate_version" --arg disk "$disk_sha" --arg edition "$edition" \
  --arg name "$(basename -- "$disk")" --argjson size "$(stat -c '%s' "$disk")" \
  '.candidateSha256==$candidate and .candidateVersion==$candidateVersion and .edition==$edition and .installedDisk.name==$name and .installedDisk.sha256==$disk and .installedDisk.size==$size' "$installation_lock" >/dev/null || { echo 'Installation lock identity/disk differs from the signed review inputs.' >&2; exit 1; }
jq -e --arg candidate "$candidate_sha" --arg lock "$(devario_sha256 "$installation_lock")" \
  --arg candidateVersion "$candidate_version" --arg disk "$disk_sha" --arg edition "$edition" '.candidateSha256==$candidate and .candidateVersion==$candidateVersion and .installationLockSha256==$lock and .installedDiskSha256==$disk and .edition==$edition' "$review" >/dev/null || {
  echo 'Installation review bindings differ from supplied evidence.' >&2; exit 1;
}
status="$(gpgv --status-fd 1 --keyring "$keyring" "$signature" "$review" 2>/dev/null)" || { echo 'Installation review signature is invalid.' >&2; exit 1; }
signer="$(awk '/^\[GNUPG:\] VALIDSIG / {print ($NF ~ /^[0-9A-F]{40,64}$/ ? $NF : $3); exit}' <<<"$status")"
[[ "$signer" == "$active" ]] || { echo 'Installation review signature did not use the active approver key.' >&2; exit 1; }
echo "Validated signed Calamares review by ZoeyErinBauer ($active)."
