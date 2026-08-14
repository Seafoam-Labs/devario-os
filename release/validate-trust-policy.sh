#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
policy='' keyring='' trusted='' revoked='' expected_purpose=''
while (( $# )); do
  case "$1" in
    --policy) policy="$2"; shift 2 ;;
    --keyring) keyring="$2"; shift 2 ;;
    --trusted) trusted="$2"; shift 2 ;;
    --revoked) revoked="$2"; shift 2 ;;
    --purpose) expected_purpose="$2"; shift 2 ;;
    *) echo 'Usage: validate-trust-policy.sh --policy FILE --keyring FILE --purpose PURPOSE [--trusted FILE --revoked FILE]' >&2; exit 2 ;;
  esac
done
for value in policy keyring expected_purpose; do
  [[ -n "${!value}" ]] || { echo "Missing $value." >&2; exit 2; }
done
python3 "$script_dir/validate-json.py" "$script_dir/trust-policy.schema.json" "$policy"
jq -e --arg purpose "$expected_purpose" '.purpose == $purpose' "$policy" >/dev/null || {
  echo 'Trust policy purpose mismatch.' >&2; exit 1;
}
active="$(jq -r '.activeFingerprint // empty' "$policy")"
[[ -n "$active" ]] || { echo 'Production trust has not been provisioned: no active fingerprint.' >&2; exit 1; }
mapfile -t approved < <(jq -r '.approvedFingerprints[]' "$policy" | sort)
(( ${#approved[@]} > 0 )) || { echo 'Production trust has no approved fingerprints.' >&2; exit 1; }
printf '%s\n' "${approved[@]}" | grep -Fqx "$active" || { echo 'Active fingerprint is not approved.' >&2; exit 1; }
while IFS= read -r fingerprint; do
  if printf '%s\n' "${approved[@]}" | grep -Fqx "$fingerprint"; then
    echo "Forbidden fingerprint is approved: $fingerprint" >&2; exit 1
  fi
done < <(jq -r '.forbiddenFingerprints[]' "$policy")

[[ -f "$keyring" && ! -L "$keyring" ]] || { echo "Missing public keyring: $keyring" >&2; exit 1; }
key_listing="$(gpg --batch --with-colons --import-options show-only --import "$keyring" 2>/dev/null)" || {
  echo 'Public keyring cannot be parsed.' >&2; exit 1;
}
if grep -Eq '^(sec|ssb):' <<<"$key_listing"; then
  echo 'Secret key material is forbidden in a release keyring.' >&2; exit 1
fi
mapfile -t actual < <(awk -F: '$1 == "pub" {want=1; next} want && $1 == "fpr" {print $10; want=0}' <<<"$key_listing" | sort -u)
if [[ "$(printf '%s\n' "${approved[@]}")" != "$(printf '%s\n' "${actual[@]}")" ]]; then
  echo 'Public keyring primary fingerprints do not exactly match the approved set.' >&2; exit 1
fi

if [[ -n "$trusted" || -n "$revoked" ]]; then
  [[ -f "$trusted" && -f "$revoked" && ! -L "$trusted" && ! -L "$revoked" ]] || {
    echo 'Both pacman trusted and revoked files are required.' >&2; exit 1;
  }
  mapfile -t trusted_fingerprints < <(sed -nE 's/^([0-9A-F]{40,64}):4:$/\1/p' "$trusted" | sort -u)
  if [[ "$(printf '%s\n' "${approved[@]}")" != "$(printf '%s\n' "${trusted_fingerprints[@]}")" ]]; then
    echo 'Pacman trusted owners do not exactly match approved primary fingerprints.' >&2; exit 1
  fi
  if grep -Ev '^[0-9A-F]{40,64}(:[0-9]+:)?$|^[[:space:]]*(#|$)' "$trusted" "$revoked" >/dev/null; then
    echo 'Pacman trust files contain malformed entries.' >&2; exit 1
  fi
  while IFS= read -r revoked_fingerprint; do
    [[ -z "$revoked_fingerprint" ]] && continue
    revoked_fingerprint="${revoked_fingerprint%%:*}"
    if printf '%s\n' "${approved[@]}" | grep -Fqx "$revoked_fingerprint"; then
      echo "Approved fingerprint is revoked: $revoked_fingerprint" >&2; exit 1
    fi
  done < <(sed -E '/^[[:space:]]*(#|$)/d' "$revoked")
fi
echo "Validated fixed $expected_purpose trust policy with active signer $active."
