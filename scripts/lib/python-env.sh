#!/usr/bin/env bash

devario_use_validation_python() {
  local helper environment
  local -a options=()
  helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/prepare-validation-env.py"
  # A controlled build must use the environment already covered by its root hash.
  if [[ "${DEVARIO_CONTROLLED_NSPAWN:-0}" == 1 ]]; then
    options+=(--check)
  fi
  environment="$(python3 -I -B "$helper" "${options[@]}")" || return 1
  export VIRTUAL_ENV="$environment"
  export PATH="$environment/bin:$PATH"
  export PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1
  unset PYTHONHOME PYTHONPATH
}
