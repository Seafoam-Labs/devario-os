#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) respective contributors
# SPDX-License-Identifier: GPL-3.0-or-later

# Common fail-closed helpers. This file is sourced by release scripts.

devario_sha256() {
  local value
  value="$(sha256sum -- "$1")" || return
  printf '%s\n' "${value%% *}"
}

devario_validate_release_version() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

devario_repo_add_link_target() {
  case "$1" in
    devario-core.db) printf '%s\n' 'devario-core.db.tar.zst' ;;
    devario-core.files) printf '%s\n' 'devario-core.files.tar.zst' ;;
    devario-core.db.sig) printf '%s\n' 'devario-core.db.tar.zst.sig' ;;
    devario-core.files.sig) printf '%s\n' 'devario-core.files.tar.zst.sig' ;;
    devario-managed.db) printf '%s\n' 'devario-managed.db.tar.zst' ;;
    devario-managed.files) printf '%s\n' 'devario-managed.files.tar.zst' ;;
    devario-managed.db.sig) printf '%s\n' 'devario-managed.db.tar.zst.sig' ;;
    devario-managed.files.sig) printf '%s\n' 'devario-managed.files.tar.zst.sig' ;;
    *) return 1 ;;
  esac
}

devario_require_repo_add_link() {
  local path="$1" expected actual
  [[ -L "$path" ]] || return 1
  expected="$(devario_repo_add_link_target "$(basename -- "$path")")" || return 1
  actual="$(readlink -- "$path")" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  [[ -f "$(dirname -- "$path")/$expected" && ! -L "$(dirname -- "$path")/$expected" ]]
}

devario_require_complete_repo_add_sets() {
  local tree="$1" directory repository name found
  while IFS= read -r -d '' directory; do
    for repository in devario-core devario-managed; do
      found=0
      for name in \
        "$repository.db.tar.zst" "$repository.files.tar.zst" \
        "$repository.db.tar.zst.sig" "$repository.files.tar.zst.sig" \
        "$repository.db" "$repository.files" \
        "$repository.db.sig" "$repository.files.sig"; do
        if [[ -e "$directory/$name" || -L "$directory/$name" ]]; then
          found=1
          break
        fi
      done
      (( found )) || continue
      for name in \
        "$repository.db.tar.zst" "$repository.files.tar.zst" \
        "$repository.db.tar.zst.sig" "$repository.files.tar.zst.sig"; do
        if [[ ! -f "$directory/$name" || -L "$directory/$name" ]]; then
          echo "Release repository set omits regular member: ${directory#"$tree/"}/$name" >&2
          return 1
        fi
      done
      for name in \
        "$repository.db" "$repository.files" \
        "$repository.db.sig" "$repository.files.sig"; do
        if ! devario_require_repo_add_link "$directory/$name"; then
          echo "Release repository set omits or misdirects canonical link: ${directory#"$tree/"}/$name" >&2
          return 1
        fi
      done
    done
  done < <(find "$tree" -type d -print0)
}

devario_require_closed_tree() {
  local tree="$1" path
  [[ -d "$tree" ]] || { echo "Missing tree: $tree" >&2; return 1; }
  while IFS= read -r -d '' path; do
    if [[ "$path" == *$'\n'* || "$path" == *$'\r'* ]]; then
      echo "Tree path contains a newline: ${path#"$tree/"}" >&2
      return 1
    fi
    if [[ -L "$path" ]]; then
      if ! devario_require_repo_add_link "$path"; then
        echo "Tree contains a non-canonical repository symlink: ${path#"$tree/"}" >&2
        return 1
      fi
    elif [[ ! -d "$path" && ! -f "$path" ]]; then
      echo "Tree contains a special entry: ${path#"$tree/"}" >&2
      return 1
    fi
    if [[ -d "$path" ]] && ! find "$path" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
      echo "Tree contains an empty directory: ${path#"$tree/"}" >&2
      return 1
    fi
  done < <(find "$tree" -mindepth 1 -print0)
  find "$tree" -type f -print -quit | grep -q . || {
    echo "Tree contains no regular files: $tree" >&2
    return 1
  }
  devario_require_complete_repo_add_sets "$tree"
}

devario_tree_json() {
  local tree="$1" output="$2" temporary path relative digest size mode target
  devario_require_closed_tree "$tree" || return
  temporary="$(mktemp /tmp/devario-tree-json.XXXXXX)" || return
  : > "$temporary"
  while IFS= read -r -d '' path; do
    relative="${path#"$tree/"}"
    if [[ -L "$path" ]]; then
      target="$(readlink -- "$path")" || { rm -f -- "$temporary"; return 1; }
      jq -cn --arg path "$relative" --arg target "$target" \
        '{path: $path, mode: "120000", target: $target}' >> "$temporary"
    else
      digest="$(devario_sha256 "$path")" || { rm -f -- "$temporary"; return 1; }
      size="$(stat -c '%s' -- "$path")" || { rm -f -- "$temporary"; return 1; }
      mode="$(stat -c '%a' -- "$path")" || { rm -f -- "$temporary"; return 1; }
      jq -cn --arg path "$relative" --arg sha256 "$digest" \
        --argjson size "$size" --arg mode "$mode" \
        '{path: $path, sha256: $sha256, size: $size, mode: $mode}' >> "$temporary"
    fi
  done < <(find "$tree" \( -type f -o -type l \) -print0 | sort -z)
  jq -s '.' "$temporary" > "$output"
  rm -f -- "$temporary"
}

devario_tree_set_digest() {
  jq -cS '.' "$1" | sha256sum | cut -d' ' -f1
}

devario_check_safe_relative_path() {
  [[ "$1" =~ ^[^/].* ]] \
    && [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]] \
    && [[ "/$1/" != *'/../'* && "$1" != *'//'* ]]
}

# Print the one candidate artifact path whose bytes, size, and final filename
# match FILE. Requiring exactly one match prevents callers from silently
# choosing between duplicate subjects in different repository subtrees.
devario_candidate_artifact_path() {
  local candidate="$1" file="$2" name digest size
  [[ -f "$candidate" && ! -L "$candidate" && -f "$file" && ! -L "$file" ]] || return 1
  name="$(basename -- "$file")"
  digest="$(devario_sha256 "$file")" || return
  size="$(stat -c '%s' -- "$file")" || return
  jq -er --arg name "$name" --arg sha256 "$digest" --argjson size "$size" '
    [.artifacts[] | select(
      .sha256 == $sha256 and .size == $size and (.path | split("/")[-1]) == $name
    )] as $matches |
    if ($matches | length) == 1 then $matches[0].path else empty end
  ' "$candidate"
}

devario_validate_inventory_source_spdx() {
  local metadata="$1"
  jq -e --slurpfile inventory "$metadata/IMAGE-PACKAGE-INVENTORY.json" '
    ([.packages[] | [.name,.version,.architecture,.packageBase]] | sort) ==
    ([$inventory[0][] | [.name,.version,.architecture,.packageBase]] | sort) and
    ([.packages[].name] | length) == ([.packages[].name] | unique | length)
  ' "$metadata/source-index.json" >/dev/null || {
    echo 'Corresponding-source index does not exactly cover the installed package inventory.' >&2
    return 1
  }
  jq -e --slurpfile inventory "$metadata/IMAGE-PACKAGE-INVENTORY.json" \
    --slurpfile sources "$metadata/source-index.json" '
    .creationInfo.creators == ["Person: ZoeyErinBauer","Tool: devario-release-metadata"] and
    ([.packages[] | {
      name, versionInfo, supplier, licenseDeclared, comment
    }] | sort_by(.name)) ==
    ([$inventory[0][] as $package |
      ($sources[0].packages[] | select(
        .name==$package.name and .version==$package.version and
        .architecture==$package.architecture and .packageBase==$package.packageBase
      )) as $source |
      {
        name:$package.name,
        versionInfo:$package.version,
        supplier:(if $package.packager=="" then "NOASSERTION" else "Organization: "+$package.packager end),
        licenseDeclared:(if ($package.licenses|length)==0 then "NOASSERTION" else ($package.licenses|join(" AND ")) end),
        comment:("architecture="+$package.architecture+"; packageBase="+$package.packageBase+"; binary="+$source.binary.path+"@"+$source.binary.sha256+"; correspondingSource="+([$source.sources[].uri]|join(",")))
      }
    ] | sort_by(.name))
  ' "$metadata/installed-packages.spdx.json" >/dev/null || {
    echo 'Installed-package SPDX is not the exact inventory-to-source mapping.' >&2
    return 1
  }
}

devario_validate_source_binary_closure() {
  local source_index="$1" artifacts="$2" path sha256 size actual_path
  while IFS=$'\t' read -r path sha256 size; do
    devario_check_safe_relative_path "$path" || {
      echo "Unsafe binary path in corresponding-source index: $path" >&2
      return 1
    }
    actual_path="$artifacts/$path"
    [[ -f "$actual_path" && ! -L "$actual_path" ]] || {
      echo "Corresponding-source binary is outside the artifact closure: $path" >&2
      return 1
    }
    [[ "$(devario_sha256 "$actual_path")" == "$sha256" \
      && "$(stat -c '%s' -- "$actual_path")" == "$size" ]] || {
      echo "Corresponding-source binary binding is stale: $path" >&2
      return 1
    }
  done < <(jq -r '.packages[].binary | [.path,.sha256,(.size|tostring)] | @tsv' "$source_index")
}
