#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if (( $# == 0 )); then
  echo 'Usage: with-validation-env.sh COMMAND [ARGUMENT ...]' >&2
  exit 2
fi
# shellcheck source=lib/python-env.sh
source "$script_dir/lib/python-env.sh"
devario_use_validation_python
exec "$@"
