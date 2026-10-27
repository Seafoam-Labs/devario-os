#!/usr/bin/env bash
# Validate the kernel selected by a previously verified repository snapshot.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_dir/validate-kernel-packages.py" "$@"
