#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
# shellcheck source=../scripts/lib/repository.sh
source "$project_dir/scripts/lib/repository.sh"
artifacts='' keyring_dir='' repository_name='devario-core'
while (( $# )); do
  case "$1" in
    --artifacts) artifacts="$2"; shift 2 ;;
    --keyring-dir) keyring_dir="$2"; shift 2 ;;
    --repository-name) repository_name="$2"; shift 2 ;;
    *) echo 'Usage: verify-repository-signatures.sh --artifacts DIR --keyring-dir DIR [--repository-name devario-core|devario-managed]' >&2; exit 2 ;;
  esac
done
[[ -d "$artifacts" && -d "$keyring_dir" ]] || { echo 'Artifact and keyring directories are required.' >&2; exit 2; }
devario_validate_keyring_bundle "$keyring_dir" "$repository_name" production
bundle="$DEVARIO_KEYRING_PUBLIC"
active="$DEVARIO_ACTIVE_SIGNER"

verified=0
while IFS= read -r -d '' artifact; do
  case "$artifact" in
    *.pkg.tar.zst|*.pkg.tar.xz|*.pkg.tar.gz|*.pkg.tar.lrz|*.pkg.tar.lzo|*.pkg.tar.Z|*.db.tar.zst|*.db.tar.xz|*.db.tar.gz|*.files.tar.zst|*.src.tar.zst|*.src.tar.xz|*.src.tar.gz)
      signature="$artifact.sig"
      [[ -f "$signature" && ! -L "$signature" ]] || { echo "Missing detached signature: ${artifact#"$artifacts/"}.sig" >&2; exit 1; }
      status="$(gpgv --status-fd 1 --keyring "$bundle" "$signature" "$artifact" 2>/dev/null)" || {
        echo "Signature verification failed: ${artifact#"$artifacts/"}" >&2; exit 1;
      }
      signer="$(awk '/^\[GNUPG:\] VALIDSIG / {print ($NF ~ /^[0-9A-F]{40,64}$/ ? $NF : $3); exit}' <<<"$status")"
      [[ "$signer" == "$active" ]] || { echo "Artifact was not signed by the active primary: ${artifact#"$artifacts/"}" >&2; exit 1; }
      verified=$((verified + 1))
      ;;
  esac
done < <(find "$artifacts" -type f ! -name '*.sig' -print0 | sort -z)
(( verified > 0 )) || { echo 'No signed package or repository artifact was found.' >&2; exit 1; }

keyring_glob='devario-keyring-*.pkg.tar.*'
if [[ "$repository_name" == devario-managed ]]; then keyring_glob='devario-managed-keyring-*.pkg.tar.*'; fi
while IFS= read -r -d '' package; do
  temporary="$(mktemp -d /tmp/devario-keyring-package.XXXXXX)"
  trap 'rm -rf -- "${temporary:-}"' EXIT
  if [[ "$repository_name" == devario-core ]]; then
    mappings=('devario.gpg:usr/share/pacman/keyrings/devario-core.gpg' 'devario-trusted:usr/share/pacman/keyrings/devario-core-trusted' 'devario-revoked:usr/share/pacman/keyrings/devario-core-revoked' 'active-signer:usr/share/devario/keyrings/devario-core-active-signer')
  else
    mappings=('devario-managed.gpg:usr/share/pacman/keyrings/devario-managed.gpg' 'devario-managed-trusted:usr/share/pacman/keyrings/devario-managed-trusted' 'devario-managed-revoked:usr/share/pacman/keyrings/devario-managed-revoked' 'active-signer:usr/share/devario/keyrings/devario-managed-active-signer')
  fi
  for mapping in "${mappings[@]}"; do
    name="${mapping%%:*}"; installed="${mapping#*:}"
    bsdtar -xOf "$package" "$installed" > "$temporary/$name" || {
      echo "Keyring package omits $installed." >&2; exit 1;
    }
    cmp -s "$temporary/$name" "$keyring_dir/$name" || { echo "Keyring package embeds a different $name." >&2; exit 1; }
  done
  rm -rf -- "$temporary"; trap - EXIT
done < <(find "$artifacts" -type f -name "$keyring_glob" -print0)

echo "Verified $verified $repository_name repository/package/source signatures against its exact active signer."
