#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

# This entry point runs from GitHub's already authenticated, immutable action
# snapshot. It deliberately performs no network access and needs no token from
# the private Managed repository.
set -euo pipefail

action_repository=''
action_ref=''
caller_repository=''
action_path=''
managed_workspace=''
context_only=0
while (( $# )); do
  case "$1" in
    --action-repository) action_repository="$2"; shift 2 ;;
    --action-ref) action_ref="$2"; shift 2 ;;
    --caller-repository) caller_repository="$2"; shift 2 ;;
    --action-path) action_path="$2"; shift 2 ;;
    --managed-workspace) managed_workspace="$2"; shift 2 ;;
    --context-only) context_only=1; shift ;;
    *) echo 'Unknown Managed action validation option.' >&2; exit 2 ;;
  esac
done
for value in action_repository action_ref caller_repository action_path managed_workspace; do
  [[ -n "${!value}" ]] || { echo "Managed action validation is missing $value." >&2; exit 2; }
done

[[ "$action_repository" == Seafoam-Labs/devario-os ]] || {
  echo 'Managed validation must invoke Seafoam-Labs/devario-os directly.' >&2
  exit 1
}
[[ "$action_ref" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'The core action must be referenced by a full lowercase commit ID.' >&2
  exit 1
}
[[ "$caller_repository" == Seafoam-Labs/devario-managed-overlay ]] || {
  echo 'The core Managed action is restricted to devario-managed-overlay.' >&2
  exit 1
}
[[ -d "$managed_workspace/.git" && -f "$managed_workspace/base.lock" && ! -L "$managed_workspace/base.lock" ]] || {
  echo 'The caller must provide a regular exact Git checkout of the Managed overlay.' >&2
  exit 1
}

action_path="$(realpath -e -- "$action_path")"
core_source="$(realpath -e -- "$action_path/../../..")"
[[ -f "$action_path/action.yml" && ! -L "$action_path/action.yml" \
  && -x "$core_source/scripts/validate-managed-action.sh" ]] || {
  echo 'The downloaded core action snapshot is incomplete.' >&2
  exit 1
}
expected_lock="devario_os_commit=$action_ref"
if [[ "$(wc -l < "$managed_workspace/base.lock")" -ne 1 ]] \
  || [[ "$(<"$managed_workspace/base.lock")" != "$expected_lock" ]]; then
  echo 'Managed base.lock does not equal the exact platform-authenticated action SHA.' >&2
  exit 1
fi
if [[ -n "$(git -C "$managed_workspace" status --porcelain=v1 --untracked-files=all --ignored=matching)" ]]; then
  echo 'Managed validation requires an exact clean caller checkout.' >&2
  exit 1
fi
if git -C "$managed_workspace" ls-files -v \
  | awk 'substr($1,1,1) == "S" || substr($1,1,1) ~ /[a-z]/ {found=1} END {exit !found}'; then
  echo 'Managed checkout uses skip-worktree or assume-unchanged flags.' >&2
  exit 1
fi
git -C "$managed_workspace" diff-index --quiet HEAD --
(( context_only )) && { echo 'Validated immutable Managed action context.'; exit 0; }

validation_root="$(mktemp -d /tmp/devario-managed-action.XXXXXX)"
cleanup_validation_root() {
  rm -rf -- "$validation_root"
}
trap cleanup_validation_root EXIT
core_snapshot="$validation_root/devario-os"
managed_snapshot="$validation_root/devario-managed-overlay"
mkdir "$core_snapshot" "$managed_snapshot"

# The core directory is the source bundle GitHub resolved for action_ref. The
# caller checkout is archived from its exact clean HEAD. Neither snapshot
# inherits mutable index state or credentials.
tar --exclude=.git -C "$core_source" -cf - . | tar -C "$core_snapshot" -xf -
git -C "$managed_workspace" archive --format=tar HEAD | tar -C "$managed_snapshot" -xf -
[[ "$(<"$managed_snapshot/base.lock")" == "$expected_lock" ]] || {
  echo 'Snapshotted Managed base.lock changed during validation setup.' >&2
  exit 1
}

export DEVARIO_CORE_DIR="$core_snapshot"
export DEVARIO_CORE_COMMIT="$action_ref"
export DEVARIO_VALIDATED_ACTION_SNAPSHOT=1
export DEVARIO_ACTION_SNAPSHOT_ROOT="$core_snapshot"
export DEVARIO_ACTION_SNAPSHOT_SENTINEL="$validation_root/action-snapshot.lock"
printf 'devario_os_commit=%s\n' "$action_ref" > "$DEVARIO_ACTION_SNAPSHOT_SENTINEL"
chmod 0444 "$DEVARIO_ACTION_SNAPSHOT_SENTINEL"
"$core_snapshot/scripts/validate.sh" --edition "$managed_snapshot"
(
  cd "$managed_snapshot"
  while IFS= read -r shell_file; do
    bash -n "$shell_file"
  done < <(find scripts release tests -type f -name '*.sh' -print | sort)
  ./scripts/validate-overlay.sh
  ./tests/test-overlay-contract.sh
  ./tests/test-managed-build-contract.sh
  python3 ./tests/test-managed-input-lock.py
)

echo 'Validated Managed overlay against the immutable downloaded core action snapshot.'
