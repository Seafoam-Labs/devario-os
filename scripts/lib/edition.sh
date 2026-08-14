#!/usr/bin/env bash

# Edition metadata is parsed as data. This file must never source edition.conf.

devario_edition_library_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "$devario_edition_library_dir/repository.sh" ]]; then
  printf 'Edition error: repository contract library is missing.\n' >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=repository.sh
source "$devario_edition_library_dir/repository.sh"
unset devario_edition_library_dir

devario_edition_error() {
  printf 'Edition error: %s\n' "$*" >&2
  return 1
}

devario_path_is_within() {
  local candidate="$1"
  local parent="$2"

  [[ "$candidate" == "$parent" || "$candidate" == "$parent/"* ]]
}

devario_require_plain_file() {
  local path="$1"
  local description="$2"

  if [[ ! -f "$path" || -L "$path" ]]; then
    devario_edition_error "$description must be a regular, non-symlink file: $path"
    return 1
  fi
}

devario_line_is_printable_ascii() {
  local value="$1"

  ! LC_ALL=C grep -q '[^ -~]' <<< "$value"
}

devario_load_edition_config() {
  local requested_edition_dir="$1"
  local config_path line key value
  local line_number=0
  declare -A values=()
  declare -A seen=()
  local required_key

  if [[ ! -d "$requested_edition_dir" ]]; then
    devario_edition_error "edition directory does not exist: $requested_edition_dir"
    return 1
  fi
  DEVARIO_EDITION_DIR="$(realpath -e -- "$requested_edition_dir")"
  config_path="$DEVARIO_EDITION_DIR/edition.conf"
  devario_require_plain_file "$config_path" 'edition.conf' || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    (( line_number += 1 ))
    if ! devario_line_is_printable_ascii "$line"; then
      devario_edition_error "edition.conf line $line_number contains non-printable or non-ASCII characters"
      return 1
    fi
    if [[ ! "$line" =~ ^([a-z_]+)=(.*)$ ]]; then
      devario_edition_error "edition.conf line $line_number must use key=value syntax"
      return 1
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    case "$key" in
      format|id|variant|iso_name|iso_label_prefix|iso_publisher|iso_application)
        ;;
      *)
        devario_edition_error "edition.conf contains unknown key: $key"
        return 1
        ;;
    esac
    if [[ -n "${seen[$key]:-}" ]]; then
      devario_edition_error "edition.conf contains duplicate key: $key"
      return 1
    fi
    if [[ -z "$value" || "$value" != "${value# }" || "$value" != "${value% }" ]]; then
      devario_edition_error "edition.conf key $key has an empty value or surrounding whitespace"
      return 1
    fi
    seen["$key"]=1
    values["$key"]="$value"
  done < "$config_path"

  for required_key in \
    format id variant iso_name iso_label_prefix iso_publisher iso_application; do
    if [[ -z "${seen[$required_key]:-}" ]]; then
      devario_edition_error "edition.conf is missing required key: $required_key"
      return 1
    fi
  done

  if [[ "${values[format]}" != 1 ]]; then
    devario_edition_error "unsupported edition contract format: ${values[format]}"
    return 1
  fi
  if [[ ! "${values[id]}" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; then
    devario_edition_error 'edition id must be 1-64 lowercase letters, digits, dots, underscores, or hyphens'
    return 1
  fi
  if [[ ! "${values[variant]}" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]{0,63}$ ]]; then
    devario_edition_error 'edition variant must be 1-64 simple printable characters'
    return 1
  fi
  if [[ ! "${values[iso_name]}" =~ ^[a-z0-9][a-z0-9._-]{0,31}$ ]]; then
    devario_edition_error 'iso_name must be 1-32 lowercase letters, digits, dots, underscores, or hyphens'
    return 1
  fi
  if [[ ! "${values[iso_label_prefix]}" =~ ^[A-Z0-9_]{1,25}$ ]]; then
    devario_edition_error 'iso_label_prefix must be 1-25 uppercase letters, digits, or underscores'
    return 1
  fi
  if (( ${#values[iso_publisher]} > 128 || ${#values[iso_application]} > 128 )); then
    devario_edition_error 'ISO publisher and application values must not exceed 128 characters'
    return 1
  fi

  DEVARIO_EDITION_FORMAT="${values[format]}"
  DEVARIO_EDITION_ID="${values[id]}"
  DEVARIO_EDITION_VARIANT="${values[variant]}"
  DEVARIO_EDITION_ISO_NAME="${values[iso_name]}"
  DEVARIO_EDITION_ISO_LABEL_PREFIX="${values[iso_label_prefix]}"
  DEVARIO_EDITION_ISO_PUBLISHER="${values[iso_publisher]}"
  DEVARIO_EDITION_ISO_APPLICATION="${values[iso_application]}"
}

devario_verify_base_lock() {
  local core_dir="$1"
  local identity_mode="${2:-normal}"
  local lock_path="$DEVARIO_EDITION_DIR/base.lock"
  local internal_editions_dir actual_commit locked_commit lock_line sentinel
  local line_count=0

  core_dir="$(realpath -e -- "$core_dir")"
  internal_editions_dir="$core_dir/editions"

  if [[ -n "${DEVARIO_CORE_COMMIT:-}" ]]; then
    if [[ ! "$DEVARIO_CORE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
      devario_edition_error 'DEVARIO_CORE_COMMIT is not a full lowercase commit ID'
      return 1
    fi
    if [[ "$identity_mode" == action-snapshot ]]; then
      sentinel="${DEVARIO_ACTION_SNAPSHOT_SENTINEL:-}"
      if [[ "${DEVARIO_VALIDATED_ACTION_SNAPSHOT:-0}" != 1 \
        || -e "$core_dir/.git" \
        || "$(realpath -e -- "${DEVARIO_ACTION_SNAPSHOT_ROOT:-/nonexistent}" 2>/dev/null || true)" != "$core_dir" \
        || ! -f "$sentinel" || -L "$sentinel" \
        || "$(<"$sentinel")" != "devario_os_commit=$DEVARIO_CORE_COMMIT" ]]; then
        devario_edition_error 'the action-snapshot identity override lacks its validation-only sentinel'
        return 1
      fi
    elif [[ "${DEVARIO_CONTROLLED_NSPAWN:-0}" == 1 \
      && "${DEVARIO_VERIFIED_SOURCE:-0}" == 1 \
      && "${DEVARIO_RELEASE_BUILD:-0}" == 1 \
      && "$core_dir" == /input/devario-os \
      && ! -e "$core_dir/.git" \
      && "${DEVARIO_INPUT_LOCK:-}" == /input/CORE-INPUT-LOCK.json \
      && -f /input/CORE-INPUT-LOCK.json ]]; then
      :
    else
      devario_edition_error 'DEVARIO_CORE_COMMIT is accepted only from a verified controlled release or immutable action snapshot'
      return 1
    fi
    actual_commit="$DEVARIO_CORE_COMMIT"
  elif [[ "$identity_mode" == action-snapshot ]]; then
    devario_edition_error 'an action snapshot requires its platform-authenticated core commit'
    return 1
  fi

  if devario_path_is_within "$DEVARIO_EDITION_DIR" "$internal_editions_dir" \
    && [[ ! -e "$lock_path" ]]; then
    return 0
  fi

  devario_require_plain_file "$lock_path" 'base.lock' || return 1
  while IFS= read -r lock_line || [[ -n "$lock_line" ]]; do
    (( line_count += 1 ))
    if (( line_count > 1 )); then
      devario_edition_error 'base.lock must contain exactly one line'
      return 1
    fi
    if [[ ! "$lock_line" =~ ^devario_os_commit=([0-9a-f]{40})$ ]]; then
      devario_edition_error 'base.lock must contain devario_os_commit=<40 lowercase hexadecimal characters>'
      return 1
    fi
    locked_commit="${BASH_REMATCH[1]}"
  done < "$lock_path"
  if (( line_count != 1 )); then
    devario_edition_error 'base.lock must contain exactly one line'
    return 1
  fi

  if [[ -z "${actual_commit:-}" ]] \
    && ! actual_commit="$(git -C "$core_dir" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)"; then
    devario_edition_error 'an external edition requires a committed devario-os checkout or its verified snapshot identity'
    return 1
  fi
  if [[ "$locked_commit" != "$actual_commit" ]]; then
    devario_edition_error "base.lock requires devario-os $locked_commit, but the checkout is $actual_commit"
    return 1
  fi
  if [[ -d "$core_dir/.git" ]] \
    && [[ -n "$(git -C "$core_dir" status --porcelain=v1 --untracked-files=all --ignored=matching)" ]]; then
    devario_edition_error 'an external edition requires a clean devario-os checkout matching base.lock'
    return 1
  fi
}

devario_read_package_list() {
  local list_path="$1"
  local output_name="$2"
  local description="$3"
  local line
  local line_number=0
  declare -n output_ref="$output_name"
  declare -A list_seen=()

  devario_require_plain_file "$list_path" "$description" || return 1
  output_ref=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    (( line_number += 1 ))
    if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then
      continue
    fi
    if ! devario_line_is_printable_ascii "$line" \
      || [[ ! "$line" =~ ^[A-Za-z0-9@._+][A-Za-z0-9@._+-]*$ ]]; then
      devario_edition_error "$description line $line_number is not one bare package name"
      return 1
    fi
    if [[ -n "${list_seen[$line]:-}" ]]; then
      devario_edition_error "$description contains duplicate package: $line"
      return 1
    fi
    list_seen["$line"]=1
    output_ref+=("$line")
  done < "$list_path"
}

devario_replacement_path_is_valid() {
  local replacement="$1"
  local relative_path segment
  local -a segments=()

  if [[ ! "$replacement" =~ ^(airootfs|late-airootfs)/[A-Za-z0-9@._+/-]+$ ]] \
    || [[ "$replacement" == */ || "$replacement" == *//* ]]; then
    return 1
  fi
  relative_path="${replacement#*/}"
  IFS='/' read -r -a segments <<< "$relative_path"
  for segment in "${segments[@]}"; do
    if [[ -z "$segment" || "$segment" == . || "$segment" == .. ]]; then
      return 1
    fi
  done
}

devario_read_replacement_list() {
  local list_path="$1"
  local output_name="$2"
  local line
  local line_number=0
  declare -n output_ref="$output_name"

  devario_require_plain_file "$list_path" 'replacements.allow' || return 1
  output_ref=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    (( line_number += 1 ))
    if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then
      continue
    fi
    if ! devario_line_is_printable_ascii "$line" \
      || ! devario_replacement_path_is_valid "$line"; then
      devario_edition_error "replacements.allow line $line_number is not a safe exact overlay path"
      return 1
    fi
    if [[ -n "${output_ref[$line]:-}" ]]; then
      devario_edition_error "replacements.allow contains duplicate path: $line"
      return 1
    fi
    output_ref["$line"]=1
  done < "$list_path"
}

devario_overlay_entry_type() {
  local path="$1"

  if [[ -L "$path" ]]; then
    printf '%s\n' symlink
  elif [[ -d "$path" ]]; then
    printf '%s\n' directory
  elif [[ -f "$path" ]]; then
    printf '%s\n' file
  else
    printf '%s\n' special
  fi
}

devario_validate_overlay_tree() {
  local source_root="$1"
  local staged_root="$2"
  local tree_name="$3"
  local allowed_name="$4"
  local used_name="$5"
  local source_path relative_path destination_path replacement_path
  local source_type destination_type symlink_target resolved_target
  declare -n allowed_ref="$allowed_name"
  declare -n used_ref="$used_name"

  [[ -d "$source_root" ]] || return 0
  if [[ -L "$source_root" ]]; then
    devario_edition_error "$tree_name must be a directory, not a symlink"
    return 1
  fi

  while IFS= read -r -d '' source_path; do
    relative_path="${source_path#"$source_root/"}"
    if ! devario_line_is_printable_ascii "$relative_path" \
      || [[ ! "$relative_path" =~ ^[A-Za-z0-9@._+/-]+$ ]] \
      || [[ "$relative_path" == */ || "$relative_path" == *//* ]]; then
      devario_edition_error "$tree_name contains a path outside the portable edition character set: $relative_path"
      return 1
    fi
    source_type="$(devario_overlay_entry_type "$source_path")"
    if [[ "$source_type" == special ]]; then
      devario_edition_error "$tree_name contains a socket, device, FIFO, or other special file: $relative_path"
      return 1
    fi
    if [[ "$source_type" == file && -x "$source_path" ]]; then
      devario_edition_error "$tree_name contains executable content; ship executable code as a package: $relative_path"
      return 1
    fi
    if [[ "$source_type" == symlink ]]; then
      symlink_target="$(readlink -- "$source_path")"
      if [[ "$symlink_target" == /* ]]; then
        devario_edition_error "$tree_name contains an absolute symlink: $relative_path"
        return 1
      fi
      resolved_target="$(realpath -m -- "$(dirname -- "$source_path")/$symlink_target")"
      if ! devario_path_is_within "$resolved_target" "$source_root"; then
        devario_edition_error "$tree_name contains a symlink that escapes its tree: $relative_path"
        return 1
      fi
    fi

    destination_path="$staged_root/$relative_path"
    replacement_path="$tree_name/$relative_path"
    if [[ -e "$destination_path" || -L "$destination_path" ]]; then
      destination_type="$(devario_overlay_entry_type "$destination_path")"
      if [[ "$source_type" == directory && "$destination_type" == directory ]]; then
        continue
      fi
      if [[ "$source_type" != "$destination_type" ]]; then
        devario_edition_error "edition overlay cannot change path type for $replacement_path ($destination_type to $source_type)"
        return 1
      fi
      if [[ -z "${allowed_ref[$replacement_path]:-}" ]]; then
        devario_edition_error "edition overlay collision is not listed in replacements.allow: $replacement_path"
        return 1
      fi
      used_ref["$replacement_path"]=1
    fi
  done < <(find -P "$source_root" -mindepth 1 -print0)
}

devario_compose_profile() {
  local base_profile_dir="$1"
  local requested_edition_dir="$2"
  local staged_profile_dir="$3"
  local core_dir="$4"
  local identity_mode="${5:-normal}"
  local package package_file replacement_path tree_name source_root staged_root
  local packages_tmp
  local -a base_packages=()
  local -a added_packages=()
  local -a removed_packages=()
  declare -A base_set=()
  declare -A add_set=()
  declare -A remove_set=()
  declare -A immutable_packages=(
    [aqueous]=1
    [aqueous-noctalia]=1
    [aqueous-session]=1
    [calamares]=1
    [ckbcomp]=1
    [devario-alpm-runtime]=1
    [devario-aqueous-desktop]=1
    [devario-base]=1
    [devario-keyring]=1
    [greetd]=1
    [limine]=1
    [linux-cachyos-lts]=1
    [linux-cachyos-lts-headers]=1
    [mkinitcpio]=1
    [mkinitcpio-archiso]=1
    [networkmanager]=1
    [noctalia]=1
    [noctalia-greeter]=1
    [shelly]=1
    [squashfs-tools]=1
    [sudo]=1
    [syslinux]=1
  )
  declare -A allowed_replacements=()
  declare -A used_replacements=()

  base_profile_dir="$(realpath -e -- "$base_profile_dir")"
  core_dir="$(realpath -e -- "$core_dir")"
  if [[ ! -d "$base_profile_dir" ]]; then
    devario_edition_error "base profile does not exist: $base_profile_dir"
    return 1
  fi
  if [[ ! -d "$staged_profile_dir" ]] \
    || [[ -n "$(find "$staged_profile_dir" -mindepth 1 -print -quit)" ]]; then
    devario_edition_error "staged profile directory must exist and be empty: $staged_profile_dir"
    return 1
  fi

  devario_load_edition_config "$requested_edition_dir" || return 1
  devario_verify_base_lock "$core_dir" "$identity_mode" || return 1
  devario_read_package_list \
    "$base_profile_dir/packages.x86_64" base_packages 'base packages.x86_64' || return 1
  devario_read_package_list \
    "$DEVARIO_EDITION_DIR/packages.add" added_packages 'packages.add' || return 1
  devario_read_package_list \
    "$DEVARIO_EDITION_DIR/packages.remove" removed_packages 'packages.remove' || return 1
  devario_load_package_sources "$DEVARIO_EDITION_DIR" added_packages || return 1
  DEVARIO_EDITION_HAS_MANAGED=0
  for package in "${added_packages[@]}"; do
    if [[ "${DEVARIO_PACKAGE_ORIGINS[$package]}" == managed ]]; then
      DEVARIO_EDITION_HAS_MANAGED=1
    fi
  done
  if [[ "$DEVARIO_EDITION_ID" == community ]] && (( DEVARIO_EDITION_HAS_MANAGED )); then
    devario_edition_error 'the Community edition cannot declare managed package origins'
    return 1
  fi
  devario_read_replacement_list \
    "$DEVARIO_EDITION_DIR/replacements.allow" allowed_replacements || return 1

  for package in "${base_packages[@]}"; do
    base_set["$package"]=1
  done
  for package in "${added_packages[@]}"; do
    if [[ -n "${base_set[$package]:-}" ]]; then
      devario_edition_error "packages.add repeats a base package: $package"
      return 1
    fi
    add_set["$package"]=1
  done
  for package in "${removed_packages[@]}"; do
    if [[ -z "${base_set[$package]:-}" ]]; then
      devario_edition_error "packages.remove names a package absent from the base: $package"
      return 1
    fi
    if [[ -n "${add_set[$package]:-}" ]]; then
      devario_edition_error "a package cannot be both added and removed: $package"
      return 1
    fi
    if [[ -n "${immutable_packages[$package]:-}" ]]; then
      devario_edition_error "packages.remove cannot remove required core package: $package"
      return 1
    fi
    remove_set["$package"]=1
  done

  cp -a -- "$base_profile_dir/." "$staged_profile_dir/"
  install -d -m 0755 "$staged_profile_dir/airootfs/usr/share/devario"
  install -m 0644 "$DEVARIO_EDITION_DIR/package-sources.conf" \
    "$staged_profile_dir/airootfs/usr/share/devario/package-sources.conf"
  packages_tmp="$(mktemp "$staged_profile_dir/.packages.x86_64.XXXXXX")"
  for package in "${base_packages[@]}"; do
    if [[ -z "${remove_set[$package]:-}" ]]; then
      printf '%s\n' "$package" >> "$packages_tmp"
    fi
  done
  for package in "${added_packages[@]}"; do
    printf '%s\n' "$package" >> "$packages_tmp"
  done
  chmod 0644 "$packages_tmp"
  mv -f -- "$packages_tmp" "$staged_profile_dir/packages.x86_64"

  for tree_name in airootfs late-airootfs; do
    source_root="$DEVARIO_EDITION_DIR/$tree_name"
    staged_root="$staged_profile_dir/$tree_name"
    devario_validate_overlay_tree \
      "$source_root" "$staged_root" "$tree_name" \
      allowed_replacements used_replacements || return 1
  done
  for replacement_path in "${!allowed_replacements[@]}"; do
    if [[ -z "${used_replacements[$replacement_path]:-}" ]]; then
      devario_edition_error "replacements.allow entry is stale or does not replace a base path: $replacement_path"
      return 1
    fi
  done

  for tree_name in airootfs late-airootfs; do
    source_root="$DEVARIO_EDITION_DIR/$tree_name"
    staged_root="$staged_profile_dir/$tree_name"
    if [[ -d "$source_root" ]]; then
      install -d -m 0755 -- "$staged_root"
      cp -a -- "$source_root/." "$staged_root/"
    fi
  done
}
