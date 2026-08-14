#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
test_root="$(mktemp -d /tmp/devario-repository-boundary.XXXXXX)"
repository="$test_root/repository"
cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT
fail() { echo "Repository-boundary test failed: $*" >&2; exit 1; }
expect_rejection() {
  local label="$1"
  if "$project_dir/scripts/verify-repository-boundary.sh" --repository "$repository" \
      >"$test_root/stdout" 2>"$test_root/stderr"; then
    fail "$label was accepted"
  fi
}

mkdir -p "$repository"
git -C "$repository" init -q
git -C "$repository" config user.name 'ZoeyErinBauer'
git -C "$repository" config user.email '40698010+ZoeyErinBauer@users.noreply.github.com'
printf '%s\n' generated > "$repository/.gitignore"
printf '%s\n' exact > "$repository/tracked"
git -C "$repository" add .
git -C "$repository" commit -qm 'boundary fixture'

archive="$test_root/source.tar"; report="$test_root/report.json"
"$project_dir/scripts/verify-repository-boundary.sh" --repository "$repository" \
  --archive "$archive" --report "$report" >/dev/null
[[ -s "$archive" && -s "$report" ]] || fail 'clean export did not emit evidence'
REPORT="$report" REPOSITORY="$repository" python3 - <<'PY'
import json, os, pathlib, subprocess
data=json.loads(pathlib.Path(os.environ["REPORT"]).read_text())
head=subprocess.check_output(["git","-C",os.environ["REPOSITORY"],"rev-parse","HEAD"],text=True).strip()
assert data["commit"] == head and len(data["archiveSha256"]) == 64
PY

printf '%s\n' dirty > "$repository/tracked"
expect_rejection 'modified tracked file'
printf '%s\n' exact > "$repository/tracked"
printf '%s\n' extra > "$repository/untracked"
expect_rejection 'untracked file'
rm -f -- "$repository/untracked"
printf '%s\n' ignored > "$repository/generated"
expect_rejection 'ignored file'
rm -f -- "$repository/generated"
chmod 0755 "$repository/tracked"
expect_rejection 'worktree executable-mode drift'
chmod 0644 "$repository/tracked"
git -C "$repository" update-index --assume-unchanged tracked
expect_rejection 'assume-unchanged index flag'
git -C "$repository" update-index --no-assume-unchanged tracked

"$project_dir/scripts/verify-repository-boundary.sh" --repository "$repository" >/dev/null
ln -s ../outside "$repository/escape"
git -C "$repository" add escape
git -C "$repository" commit -qm 'escaping symlink fixture'
expect_rejection 'committed symlink escaping the repository'
echo 'Repository-boundary tests passed.'
