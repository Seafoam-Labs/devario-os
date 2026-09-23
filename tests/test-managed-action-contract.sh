#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
action="$project_dir/.github/actions/validate-managed/action.yml"
validator="$project_dir/scripts/validate-managed-action.sh"
test_root="$(mktemp -d /tmp/devario-managed-action-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

# The action downloader must be able to materialize every source symlink on a
# host with no image packages installed. Image-only links belong in build staging.
python3 - "$project_dir" <<'PY'
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
if (root / ".git").exists():
    names = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z"]).decode().split("\0")
    paths = (root / name for name in names if name)
else:
    paths = root.rglob("*")
for path in paths:
    if path.is_symlink():
        target = path.resolve(strict=True)
        if path.readlink().is_absolute() or not target.is_relative_to(root):
            raise SystemExit(f"Action source symlink escapes its archive: {path.relative_to(root)}")
PY

if grep -Eqi 'git[[:space:]]+(fetch|clone)|curl|wget|secrets\.|github\.token' "$action" "$validator"; then
  echo 'Managed composite action contains network retrieval or external-secret access.' >&2
  exit 1
fi
for required_text in \
  'github.action_repository' \
  'github.action_ref' \
  'persist-credentials' \
  'DEVARIO_CORE_DIR' \
  'devario_os_commit=' \
  'git -C "$managed_workspace" archive'; do
  if ! grep -R -Fq -- "$required_text" "$project_dir/.github" "$validator"; then
    echo "Managed action contract omits: $required_text" >&2
    exit 1
  fi
done

managed="$test_root/devario-managed-overlay"
mkdir "$managed"
git -C "$managed" init -q
git -C "$managed" config user.name ZoeyErinBauer
git -C "$managed" config user.email 40698010+ZoeyErinBauer@users.noreply.github.com
core_ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf 'devario_os_commit=%s\n' "$core_ref" > "$managed/base.lock"
git -C "$managed" add base.lock
git -C "$managed" commit -qm 'managed action fixture'

args=(
  --action-repository Seafoam-Labs/devario-os
  --action-ref "$core_ref"
  --caller-repository Seafoam-Labs/devario-managed-overlay
  --action-path "$project_dir/.github/actions/validate-managed"
  --managed-workspace "$managed"
  --context-only
)
"$validator" "${args[@]}" >/dev/null

if "$validator" --action-repository Seafoam-Labs/devario-os --action-ref main \
  --caller-repository Seafoam-Labs/devario-managed-overlay \
  --action-path "$project_dir/.github/actions/validate-managed" \
  --managed-workspace "$managed" --context-only >/dev/null 2>&1; then
  echo 'Managed action accepted a mutable core ref.' >&2
  exit 1
fi
printf 'dirty\n' > "$managed/untracked"
if "$validator" "${args[@]}" >/dev/null 2>&1; then
  echo 'Managed action accepted a dirty caller checkout.' >&2
  exit 1
fi

echo 'Managed composite action contract tests passed.'
