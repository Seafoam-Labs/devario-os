#!/usr/bin/env bash
set -euo pipefail

repository='.'
expected_commit=''
archive_output=''
report_output=''

usage() {
  cat <<'EOF'
Usage: verify-repository-boundary.sh [options]

Prove that a Git checkout is an exact, clean, ordinary-file representation of
HEAD. Ignored build products, untracked files, index flags, submodules, special
files, and worktree/index mode differences all fail closed.

Options:
  --repository DIR       checkout to verify (default: current directory)
  --expected-commit SHA  require this full commit ID
  --archive FILE         atomically write a git-archive tar of the verified HEAD
  --report FILE          atomically write canonical JSON identity metadata
EOF
}

while (( $# )); do
  case "$1" in
    --repository) (( $# >= 2 )) || exit 2; repository="$2"; shift 2 ;;
    --expected-commit) (( $# >= 2 )) || exit 2; expected_commit="$2"; shift 2 ;;
    --archive) (( $# >= 2 )) || exit 2; archive_output="$2"; shift 2 ;;
    --report) (( $# >= 2 )) || exit 2; report_output="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command_name in git python3 sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done
repository="$(realpath -e -- "$repository")"
git -C "$repository" rev-parse --is-inside-work-tree 2>/dev/null \
  | grep -Fqx true || { echo "Not a Git checkout: $repository" >&2; exit 1; }

commit="$(git -C "$repository" rev-parse --verify 'HEAD^{commit}')"
tree="$(git -C "$repository" rev-parse --verify 'HEAD^{tree}')"
if [[ -n "$expected_commit" && "$commit" != "$expected_commit" ]]; then
  echo "Checkout commit $commit does not match required commit $expected_commit." >&2
  exit 1
fi
if [[ -n "$(git -C "$repository" status --porcelain=v1 --untracked-files=all --ignored=matching)" ]]; then
  echo 'The checkout contains staged, modified, untracked, or ignored material.' >&2
  git -C "$repository" status --short --untracked-files=all --ignored=matching >&2
  exit 1
fi
if git -C "$repository" ls-files -u | grep -q .; then
  echo 'The checkout index contains unresolved entries.' >&2
  exit 1
fi
if git -C "$repository" ls-files -v -z \
  | python3 -c 'import sys
items=sys.stdin.buffer.read().split(b"\0")
bad=[x for x in items if x and chr(x[0]) != "H"]
if bad:
    for item in bad:
        print("non-default index flag: " + item.decode("utf-8", "replace"), file=sys.stderr)
    raise SystemExit(1)' ; then
  :
else
  echo 'The checkout uses assume-unchanged, skip-worktree, or another non-default index flag.' >&2
  exit 1
fi

git -C "$repository" ls-files --stage -z \
  | REPOSITORY_ROOT="$repository" python3 -c 'import os, stat, sys
root=os.environ["REPOSITORY_ROOT"]
for record in sys.stdin.buffer.read().split(b"\0"):
    if not record:
        continue
    metadata, raw_path=record.split(b"\t", 1)
    mode, _object_id, stage=metadata.decode("ascii").split()
    if stage != "0" or mode not in {"100644", "100755", "120000"}:
        raise SystemExit(f"unsupported tracked entry mode/stage: {mode} {stage} {os.fsdecode(raw_path)}")
    path=os.path.join(os.fsencode(root), raw_path)
    value=os.lstat(path).st_mode
    if mode == "120000":
        if not stat.S_ISLNK(value):
            raise SystemExit(f"tracked symlink is not a symlink: {os.fsdecode(raw_path)}")
        target=os.readlink(path)
        if target.startswith(b"/") or b"\n" in target or b"\r" in target:
            raise SystemExit(f"tracked symlink has an absolute or malformed target: {os.fsdecode(raw_path)}")
        resolved=os.path.normpath(os.path.join(os.path.dirname(raw_path), target))
        if resolved == b".." or resolved.startswith(b"../"):
            raise SystemExit(f"tracked symlink escapes the repository: {os.fsdecode(raw_path)} -> {os.fsdecode(target)}")
    else:
        if not stat.S_ISREG(value):
            raise SystemExit(f"tracked file is not regular: {os.fsdecode(raw_path)}")
        executable=bool(value & 0o111)
        if executable != (mode == "100755"):
            raise SystemExit(f"tracked executable mode differs from the index: {os.fsdecode(raw_path)}")'

archive_sha256=''
temporary_archive=''
cleanup() { [[ -z "$temporary_archive" ]] || rm -f -- "$temporary_archive"; }
trap cleanup EXIT
if [[ -n "$archive_output" ]]; then
  archive_output="$(realpath -m -- "$archive_output")"
  install -d -m 0755 "$(dirname -- "$archive_output")"
  temporary_archive="$(mktemp "$(dirname -- "$archive_output")/.devario-archive.XXXXXX")"
  git -C "$repository" archive --format=tar "$commit" > "$temporary_archive"
  chmod 0444 "$temporary_archive"
  archive_sha256="$(sha256sum "$temporary_archive")"
  archive_sha256="${archive_sha256%% *}"
  mv -f -- "$temporary_archive" "$archive_output"
  temporary_archive=''
fi

if [[ -n "$report_output" ]]; then
  report_output="$(realpath -m -- "$report_output")"
  install -d -m 0755 "$(dirname -- "$report_output")"
  tree_listing_sha256="$(git -C "$repository" ls-tree -r -z "$commit" | sha256sum)"
  tree_listing_sha256="${tree_listing_sha256%% *}"
  source_date_epoch="$(git -C "$repository" show -s --format=%ct "$commit")"
  temporary_report="$(mktemp "$(dirname -- "$report_output")/.devario-report.XXXXXX")"
  COMMIT="$commit" TREE="$tree" TREE_LISTING_SHA256="$tree_listing_sha256" \
  SOURCE_DATE_EPOCH="$source_date_epoch" ARCHIVE_SHA256="$archive_sha256" \
    python3 -c 'import json, os, sys
data={
 "schemaVersion": 1,
 "commit": os.environ["COMMIT"],
 "tree": os.environ["TREE"],
 "treeListingSha256": os.environ["TREE_LISTING_SHA256"],
 "sourceDateEpoch": int(os.environ["SOURCE_DATE_EPOCH"]),
}
if os.environ["ARCHIVE_SHA256"]:
 data["archiveSha256"]=os.environ["ARCHIVE_SHA256"]
json.dump(data, sys.stdout, sort_keys=True, separators=(",", ":"))
sys.stdout.write("\n")' > "$temporary_report"
  chmod 0444 "$temporary_report"
  mv -f -- "$temporary_report" "$report_output"
fi

printf 'Verified exact Git tree %s (%s)\n' "$commit" "$tree"
