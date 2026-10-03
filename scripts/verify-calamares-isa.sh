#!/usr/bin/env bash
# Inspect the package payload before allowing it into an ISO.
set -euo pipefail
if (( $# != 1 )); then
  echo 'Usage: verify-calamares-isa.sh CALAMARES_ARCHIVE' >&2
  exit 2
fi
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
stage="$(mktemp -d /tmp/devario-calamares-isa.XXXXXX)"
trap 'rm -rf -- "$stage"' EXIT
bsdtar --no-same-owner --no-same-permissions -xf "$1" -C "$stage"
[[ -f "$stage/usr/bin/calamares" ]] || { echo 'Calamares executable is missing.' >&2; exit 1; }
python3 "$script_dir/../packages/calamares/verify-isa.py" "$stage"
