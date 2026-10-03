#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/python-env.sh
source "$script_dir/lib/python-env.sh"
devario_use_validation_python
exec python3 "$script_dir/core-input-lock.py" "$@"
