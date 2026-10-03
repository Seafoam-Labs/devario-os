#!/usr/bin/env bash

# Repository, package-source, and public-key trust helpers shared by the
# package and image builders. This library deliberately parses configuration as
# data; callers must never source package-sources.conf or key metadata.

DEVARIO_DEVELOPMENT_FINGERPRINT='E199A52D6C3B80057E08C7BB645354F2E56FEC5D'
DEVARIO_MANAGED_DEVELOPMENT_FINGERPRINT='580E40BB6D6E8745D69D89CC6E6C90512593874C'
DEVARIO_FORBIDDEN_DEVELOPMENT_FINGERPRINTS=(
  "$DEVARIO_DEVELOPMENT_FINGERPRINT"
  "$DEVARIO_MANAGED_DEVELOPMENT_FINGERPRINT"
)

devario_repository_error() {
  printf 'Repository error: %s\n' "$*" >&2
  return 1
}

devario_is_plain_file() {
  [[ -f "$1" && ! -L "$1" ]]
}

devario_validate_repository_name() {
  case "$1" in
    devario-core|devario-managed) return 0 ;;
    *) devario_repository_error "unsupported repository identity: $1" ;;
  esac
}

devario_validate_https_url() {
  local url="$1"
  local authority port

  if [[ ! "$url" =~ ^https://([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~!$\&\'\(\)*+,\;=:/-]*)?$ ]] \
    || [[ "$url" == *'@'* || "$url" == *'?'* || "$url" == *'#'* \
      || "$url" == *'\\'* || "$url" == *'%'* || "$url" == */../* \
      || "$url" == */./* || "$url" == */.. || "$url" == */. ]]; then
    devario_repository_error 'repository URLs must be credential-free HTTPS URLs without query strings or fragments'
    return 1
  fi
  authority="${url#https://}"
  authority="${authority%%/*}"
  if [[ "${url#https://}" == *//* ]]; then
    devario_repository_error 'repository URL paths must use a canonical single slash'
    return 1
  fi
  if [[ "$authority" == *:* ]]; then
    port="${authority##*:}"
    if (( 10#$port < 1 || 10#$port > 65535 )); then
      devario_repository_error 'repository URL port is outside the valid range'
      return 1
    fi
  fi
}

devario_validate_release_version() {
  local value="$1"
  if (( ${#value} < 1 || ${#value} > 64 )) \
    || [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    devario_repository_error 'release version must match [A-Za-z0-9][A-Za-z0-9._-]{0,63}'
    return 1
  fi
}

devario_load_package_sources() {
  local edition_dir="$1"
  local expected_packages_name="$2"
  local config_path="$edition_dir/package-sources.conf"
  local line package origin expected
  local line_number=0
  declare -n expected_packages_ref="$expected_packages_name"
  declare -A expected_set=()

  declare -gA DEVARIO_PACKAGE_ORIGINS=()
  if ! devario_is_plain_file "$config_path"; then
    devario_repository_error "package-sources.conf must be a regular, non-symlink file: $config_path"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    (( line_number += 1 ))
    if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then
      continue
    fi
    if LC_ALL=C grep -q '[^ -~]' <<< "$line" \
      || [[ ! "$line" =~ ^([A-Za-z0-9@._+][A-Za-z0-9@._+-]*)=(arch|core|managed)$ ]]; then
      devario_repository_error "package-sources.conf line $line_number must be package_name=arch|core|managed"
      return 1
    fi
    package="${BASH_REMATCH[1]}"
    origin="${BASH_REMATCH[2]}"
    if [[ -n "${DEVARIO_PACKAGE_ORIGINS[$package]:-}" ]]; then
      devario_repository_error "duplicate package origin mapping: $package"
      return 1
    fi
    DEVARIO_PACKAGE_ORIGINS["$package"]="$origin"
  done < "$config_path"

  for expected in "${expected_packages_ref[@]}"; do expected_set["$expected"]=1; done
  for package in "${expected_packages_ref[@]}"; do
    if [[ -z "${DEVARIO_PACKAGE_ORIGINS[$package]:-}" ]]; then
      devario_repository_error "package-sources.conf is missing packages.add entry: $package"
      return 1
    fi
  done
  for package in "${!DEVARIO_PACKAGE_ORIGINS[@]}"; do
    if [[ -z "${expected_set[$package]:-}" ]]; then
      devario_repository_error "package-sources.conf contains an extra mapping: $package"
      return 1
    fi
  done
}

devario_keyring_paths() {
  local bundle_dir="$1"
  local repository_name="$2"

  devario_validate_repository_name "$repository_name" || return 1
  if [[ "$repository_name" == devario-core ]]; then
    # The source package retains its historic short filenames. The package
    # installs them under the unambiguous devario-core prefix.
    DEVARIO_KEYRING_PUBLIC="$bundle_dir/devario.gpg"
    DEVARIO_KEYRING_TRUSTED="$bundle_dir/devario-trusted"
    DEVARIO_KEYRING_REVOKED="$bundle_dir/devario-revoked"
  else
    DEVARIO_KEYRING_PUBLIC="$bundle_dir/$repository_name.gpg"
    DEVARIO_KEYRING_TRUSTED="$bundle_dir/$repository_name-trusted"
    DEVARIO_KEYRING_REVOKED="$bundle_dir/$repository_name-revoked"
  fi
  DEVARIO_KEYRING_ACTIVE="$bundle_dir/active-signer"
}

devario_read_fingerprint_file() {
  local path="$1"
  local output_name="$2"
  local suffix="${3:-}"
  local line fingerprint
  local line_number=0
  declare -n output_ref="$output_name"
  declare -A seen=()

  output_ref=()
  devario_is_plain_file "$path" || {
    devario_repository_error "missing key metadata file: $path"
    return 1
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    (( line_number += 1 ))
    [[ -n "$line" ]] || continue
    fingerprint="$line"
    if [[ -n "$suffix" ]]; then
      if [[ "$fingerprint" != *"$suffix" ]]; then
        devario_repository_error "invalid trust record at $path:$line_number"
        return 1
      fi
      fingerprint="${fingerprint%"$suffix"}"
    fi
    if [[ ! "$fingerprint" =~ ^[0-9A-F]{40}([0-9A-F]{24})?$ ]]; then
      devario_repository_error "invalid primary-key fingerprint at $path:$line_number"
      return 1
    fi
    if [[ -n "${seen[$fingerprint]:-}" ]]; then
      devario_repository_error "duplicate fingerprint in $path: $fingerprint"
      return 1
    fi
    seen["$fingerprint"]=1
    output_ref+=("$fingerprint")
  done < "$path"
}

devario_validate_keyring_bundle() {
  local bundle_dir="$1"
  local repository_name="$2"
  local policy="${3:-development}"
  local active line fingerprint validity uid
  declare -a trusted=() revoked=() public_fingerprints=() public_uids=()
  declare -A public_set=() trusted_set=() revoked_set=()

  declare -ga DEVARIO_PUBLIC_FINGERPRINTS=()

  devario_keyring_paths "$bundle_dir" "$repository_name" || return 1
  for path in "$DEVARIO_KEYRING_PUBLIC" "$DEVARIO_KEYRING_TRUSTED" \
    "$DEVARIO_KEYRING_REVOKED" "$DEVARIO_KEYRING_ACTIVE"; do
    devario_is_plain_file "$path" || {
      devario_repository_error "keyring bundle is incomplete: $path"
      return 1
    }
  done
  [[ -s "$DEVARIO_KEYRING_PUBLIC" ]] || {
    devario_repository_error "public keyring is empty: $DEVARIO_KEYRING_PUBLIC"
    return 1
  }

  if gpg --batch --list-packets "$DEVARIO_KEYRING_PUBLIC" 2>/dev/null \
    | grep -Eq '^:(secret key|secret sub key) packet:'; then
    devario_repository_error 'a public keyring contains secret OpenPGP packets'
    return 1
  fi
  while IFS=: read -r record validity _ _ _ _ _ _ _ field _; do
    case "$record" in
      pub)
        if [[ "$validity" == r || "$validity" == e || "$validity" == d ]]; then
          devario_repository_error 'the public bundle contains an unusable primary key'
          return 1
        fi
        ;;
      fpr)
        # Only the first fingerprint following each pub is a primary key. A
        # subkey record resets the marker below.
        if [[ "${expect_primary_fpr:-0}" == 1 ]]; then
          public_fingerprints+=("$field")
          public_set["$field"]=1
          expect_primary_fpr=0
        fi
        ;;
      uid)
        public_uids+=("$field")
        ;;
      sub) expect_primary_fpr=0 ;;
    esac
    [[ "$record" == pub ]] && expect_primary_fpr=1
  done < <(gpg --batch --with-colons --import-options show-only --import "$DEVARIO_KEYRING_PUBLIC" 2>/dev/null)

  if (( ${#public_fingerprints[@]} == 0 )); then
    devario_repository_error 'the public keyring contains no primary public keys'
    return 1
  fi
  devario_read_fingerprint_file "$DEVARIO_KEYRING_TRUSTED" trusted ':4:' || return 1
  devario_read_fingerprint_file "$DEVARIO_KEYRING_REVOKED" revoked || return 1
  if (( ${#trusted[@]} == 0 )); then
    devario_repository_error 'the keyring must trust at least one primary key'
    return 1
  fi
  for fingerprint in "${trusted[@]}"; do trusted_set["$fingerprint"]=1; done
  for fingerprint in "${revoked[@]}"; do revoked_set["$fingerprint"]=1; done
  for fingerprint in "${public_fingerprints[@]}"; do
    if [[ -n "${trusted_set[$fingerprint]:-}" && -n "${revoked_set[$fingerprint]:-}" ]]; then
      devario_repository_error "key is both trusted and revoked: $fingerprint"
      return 1
    fi
    if [[ -z "${trusted_set[$fingerprint]:-}" && -z "${revoked_set[$fingerprint]:-}" ]]; then
      devario_repository_error "public key is not classified as trusted or revoked: $fingerprint"
      return 1
    fi
  done
  for fingerprint in "${trusted[@]}" "${revoked[@]}"; do
    if [[ -z "${public_set[$fingerprint]:-}" ]]; then
      devario_repository_error "key metadata names a key absent from the public bundle: $fingerprint"
      return 1
    fi
  done

  devario_read_fingerprint_file "$DEVARIO_KEYRING_ACTIVE" active_fingerprints || return 1
  if (( ${#active_fingerprints[@]} != 1 )); then
    devario_repository_error 'active-signer must contain exactly one primary-key fingerprint'
    return 1
  fi
  active="${active_fingerprints[0]}"
  if [[ -z "${trusted_set[$active]:-}" || -n "${revoked_set[$active]:-}" ]]; then
    devario_repository_error 'active-signer must select a trusted, non-revoked primary key'
    return 1
  fi
  DEVARIO_ACTIVE_SIGNER="$active"
  DEVARIO_PUBLIC_FINGERPRINTS=("${public_fingerprints[@]}")

  if [[ "$policy" == production ]]; then
    for fingerprint in "${DEVARIO_FORBIDDEN_DEVELOPMENT_FINGERPRINTS[@]}"; do
      if [[ -n "${public_set[$fingerprint]:-}" ]]; then
        devario_repository_error "known development key is forbidden for production: $fingerprint"
        return 1
      fi
    done
    for uid in "${public_uids[@]}"; do
      if [[ "${uid,,}" == *'.invalid'* ]]; then
        devario_repository_error 'production public keys must not contain .invalid identities'
        return 1
      fi
    done
  elif [[ "$policy" != development ]]; then
    devario_repository_error "unknown keyring policy: $policy"
    return 1
  fi
}

devario_verify_keyring_package() {
  local package="$1" bundle_dir="$2" repository_name="$3" prefix
  local listing member_listing count temporary_dir extracted error_message=''
  local -a source_files=() installed_files=()
  devario_keyring_paths "$bundle_dir" "$repository_name" || return 1
  prefix="$repository_name"
  source_files=(
    "$DEVARIO_KEYRING_PUBLIC" "$DEVARIO_KEYRING_TRUSTED"
    "$DEVARIO_KEYRING_REVOKED" "$DEVARIO_KEYRING_ACTIVE"
  )
  installed_files=(
    "usr/share/pacman/keyrings/$prefix.gpg"
    "usr/share/pacman/keyrings/$prefix-trusted"
    "usr/share/pacman/keyrings/$prefix-revoked"
    "usr/share/devario/keyrings/$prefix-active-signer"
  )
  devario_is_plain_file "$package" || {
    devario_repository_error "keyring package is unavailable or unsafe: $package"
    return 1
  }
  if ! listing="$(bsdtar -tf "$package")"; then
    devario_repository_error "keyring package archive is unreadable: $package"
    return 1
  fi
  temporary_dir="$(mktemp -d /tmp/devario-keyring-package.XXXXXX)" || return 1
  local index
  for index in "${!source_files[@]}"; do
    count="$(awk -v expected="${installed_files[$index]}" \
      '$0 == expected { count += 1 } END { print count + 0 }' <<< "$listing")"
    if [[ "$count" != 1 ]]; then
      error_message="packaged $repository_name trust member must occur exactly once: ${installed_files[$index]}"
      break
    fi
    if ! member_listing="$(bsdtar -tvf "$package" "${installed_files[$index]}")" \
      || [[ -z "$member_listing" || "$member_listing" == *$'\n'* \
        || "$member_listing" != -* ]]; then
      error_message="packaged $repository_name trust member is not one regular file: ${installed_files[$index]}"
      break
    fi
    extracted="$temporary_dir/$index"
    if ! bsdtar -xOf "$package" "${installed_files[$index]}" > "$extracted"; then
      error_message="packaged $repository_name trust member cannot be extracted: ${installed_files[$index]}"
      break
    fi
    if ! cmp -s "${source_files[$index]}" "$extracted"; then
      error_message="packaged $repository_name trust differs at ${installed_files[$index]}"
      break
    fi
  done
  rm -rf -- "$temporary_dir"
  if [[ -n "$error_message" ]]; then
    devario_repository_error "$error_message"
    return 1
  fi
}

devario_require_disjoint_fingerprint_sets() {
  local left_name="$1" right_name="$2" fingerprint
  declare -n left_ref="$left_name" right_ref="$right_name"
  declare -A seen=()
  for fingerprint in "${left_ref[@]}"; do seen["$fingerprint"]=1; done
  for fingerprint in "${right_ref[@]}"; do
    if [[ -n "${seen[$fingerprint]:-}" ]]; then
      devario_repository_error "core and managed trust bundles overlap at $fingerprint"
      return 1
    fi
  done
}

devario_require_active_secret_signer() {
  local signing_home="$1"
  local requested_key="$2"
  local fingerprint

  if [[ -z "$requested_key" ]]; then
    requested_key="$DEVARIO_ACTIVE_SIGNER"
  fi
  fingerprint="$(GNUPGHOME="$signing_home" gpg --batch --with-colons \
    --list-secret-keys "$requested_key" 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10; exit }')"
  if [[ -z "$fingerprint" || "$fingerprint" != "$DEVARIO_ACTIVE_SIGNER" ]]; then
    devario_repository_error 'the selected secret key is not the bundle active-signer'
    return 1
  fi
  DEVARIO_SIGNING_FINGERPRINT="$fingerprint"
}

devario_gpgv_active_signature() {
  local signature="$1"
  local artifact="$2"
  local status valid_count=0 signing_fingerprint primary_fingerprint

  if ! status="$(gpgv --status-fd 1 --keyring "$DEVARIO_KEYRING_PUBLIC" \
    "$signature" "$artifact" 2>/dev/null)"; then
    devario_repository_error "signature verification failed: $(basename -- "$artifact")"
    return 1
  fi
  while IFS= read -r line; do
    if [[ "$line" == '[GNUPG:] VALIDSIG '* ]]; then
      read -r _ _ signing_fingerprint _ _ _ _ _ _ _ _ primary_fingerprint \
        <<< "$line"
      (( valid_count += 1 ))
      # A signing subkey fingerprint may appear first; the last field is the
      # primary fingerprint. For direct-primary signatures both are equal.
      if [[ "$primary_fingerprint" != "$DEVARIO_ACTIVE_SIGNER" ]]; then
        devario_repository_error "artifact was not signed by active-signer: $(basename -- "$artifact")"
        return 1
      fi
      if [[ ! "$signing_fingerprint" =~ ^[0-9A-F]{40}([0-9A-F]{24})?$ ]]; then
        devario_repository_error "signature lacks a full signing-key fingerprint: $(basename -- "$artifact")"
        return 1
      fi
    fi
  done <<< "$status"
  if (( valid_count != 1 )); then
    devario_repository_error "artifact must carry exactly one valid active-signer signature: $(basename -- "$artifact")"
    return 1
  fi
}

devario_inventory_packages() {
  local output_name="$1"
  shift
  local package metadata name version architecture filename size digest
  declare -n output_ref="$output_name"
  output_ref=()
  for package in "$@"; do
    metadata="$(bsdtar -xOf "$package" .PKGINFO)" || return 1
    name="$(awk -F ' = ' '$1 == "pkgname" {print $2; exit}' <<< "$metadata")"
    version="$(awk -F ' = ' '$1 == "pkgver" {print $2; exit}' <<< "$metadata")"
    architecture="$(awk -F ' = ' '$1 == "arch" {print $2; exit}' <<< "$metadata")"
    filename="$(basename -- "$package")"
    size="$(stat -c '%s' "$package")"
    digest="$(sha256sum "$package")"; digest="${digest%% *}"
    if [[ ! "$name" =~ ^[A-Za-z0-9@._+-]+$ || -z "$version" \
      || "$architecture" != any && "$architecture" != x86_64 \
      || ! "$size" =~ ^[0-9]+$ || ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
      devario_repository_error "invalid package identity: $filename"
      return 1
    fi
    output_ref+=("$name"$'\t'"$version"$'\t'"$architecture"$'\t'"$filename"$'\t'"$size"$'\t'"$digest")
  done
  mapfile -t output_ref < <(printf '%s\n' "${output_ref[@]}" | LC_ALL=C sort)
}

devario_inventory_database() {
  local database="$1"
  local output_name="$2"
  local member metadata name version architecture filename size digest
  local -a members=()
  declare -n output_ref="$output_name"
  output_ref=()
  mapfile -t members < <(bsdtar -tf "$database") || return 1
  for member in "${members[@]}"; do
    [[ "$member" == */desc ]] || continue
    if [[ ! "$member" =~ ^[A-Za-z0-9@._+:-]+/desc$ ]]; then
      devario_repository_error "unsafe repository database member: $member"
      return 1
    fi
    metadata="$(bsdtar -xOf "$database" "$member")" || return 1
    name="$(awk '$0 == "%NAME%" {getline; print; exit}' <<< "$metadata")"
    version="$(awk '$0 == "%VERSION%" {getline; print; exit}' <<< "$metadata")"
    architecture="$(awk '$0 == "%ARCH%" {getline; print; exit}' <<< "$metadata")"
    filename="$(awk '$0 == "%FILENAME%" {getline; print; exit}' <<< "$metadata")"
    size="$(awk '$0 == "%CSIZE%" {getline; print; exit}' <<< "$metadata")"
    digest="$(awk '$0 == "%SHA256SUM%" {getline; print; exit}' <<< "$metadata")"
    if [[ ! "$name" =~ ^[A-Za-z0-9@._+-]+$ || -z "$version" \
      || "$architecture" != any && "$architecture" != x86_64 \
      || ! "$filename" =~ ^[^/[:space:]]+\.pkg\.tar\.zst$ \
      || ! "$size" =~ ^[0-9]+$ || ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
      devario_repository_error "incomplete repository database record: $member"
      return 1
    fi
    output_ref+=("$name"$'\t'"$version"$'\t'"$architecture"$'\t'"$filename"$'\t'"$size"$'\t'"$digest")
  done
  (( ${#output_ref[@]} > 0 )) || {
    devario_repository_error "repository database contains no package records: $database"
    return 1
  }
  mapfile -t output_ref < <(printf '%s\n' "${output_ref[@]}" | LC_ALL=C sort)
}

devario_verify_repository() {
  local repo_dir="$1"
  local repository_name="$2"
  local keyring_dir="$3"
  local policy="${4:-development}"
  local database="$repo_dir/$repository_name.db.tar.zst"
  local files_database="$repo_dir/$repository_name.files.tar.zst"
  local path basename target package_name repository_is_signed=0
  declare -A package_names=()
  local -a packages=() expected_inventory=() database_inventory=() files_inventory=()

  devario_validate_keyring_bundle "$keyring_dir" "$repository_name" "$policy" || return 1
  [[ -d "$repo_dir" && ! -L "$repo_dir" ]] || {
    devario_repository_error "repository directory is unavailable: $repo_dir"
    return 1
  }
  devario_is_plain_file "$database" && [[ -s "$database" ]] || {
    devario_repository_error "repository database is missing: $database"
    return 1
  }
  devario_is_plain_file "$files_database" && [[ -s "$files_database" ]] || {
    devario_repository_error "repository files database is missing: $files_database"
    return 1
  }
  for basename in "$repository_name.db" "$repository_name.files"; do
    [[ -L "$repo_dir/$basename" \
      && "$(readlink -- "$repo_dir/$basename")" == "$basename.tar.zst" ]] || {
      devario_repository_error "repository compatibility link is missing or non-canonical: $basename"
      return 1
    }
  done
  for basename in \
    "$repository_name.db.tar.zst.sig" "$repository_name.files.tar.zst.sig" \
    "$repository_name.db.sig" "$repository_name.files.sig"; do
    [[ ! -e "$repo_dir/$basename" && ! -L "$repo_dir/$basename" ]] \
      || repository_is_signed=1
  done
  if [[ "$policy" == production ]]; then repository_is_signed=1; fi
  if (( repository_is_signed )); then
    for basename in "$repository_name.db" "$repository_name.files"; do
      devario_is_plain_file "$repo_dir/$basename.tar.zst.sig" \
        && [[ -s "$repo_dir/$basename.tar.zst.sig" ]] || {
        devario_repository_error "signed repository lacks $basename.tar.zst.sig"
        return 1
      }
      [[ -L "$repo_dir/$basename.sig" \
        && "$(readlink -- "$repo_dir/$basename.sig")" == "$basename.tar.zst.sig" ]] || {
        devario_repository_error "repository signature compatibility link is missing or non-canonical: $basename.sig"
        return 1
      }
    done
  fi

  shopt -s nullglob
  packages=("$repo_dir"/*.pkg.tar.zst)
  shopt -u nullglob
  (( ${#packages[@]} > 0 )) || {
    devario_repository_error "repository contains no package archives: $repo_dir"
    return 1
  }

  while IFS= read -r -d '' path; do
    basename="$(basename -- "$path")"
    if [[ -L "$path" ]]; then
      target="$(readlink -- "$path")"
      if [[ "$target" == */* || ! -f "$repo_dir/$target" ]]; then
        devario_repository_error "repository symlink is unsafe or dangling: $basename"
        return 1
      fi
      case "$basename" in
        "$repository_name.db"|"$repository_name.files"|"$repository_name.db.sig"|"$repository_name.files.sig") ;;
        *) devario_repository_error "unexpected repository symlink: $basename"; return 1 ;;
      esac
    elif [[ ! -f "$path" ]]; then
      devario_repository_error "repository contains a special filesystem entry: $basename"
      return 1
    else
      case "$basename" in
        *.pkg.tar.zst|*.pkg.tar.zst.sig|"$repository_name.db.tar.zst"|"$repository_name.db.tar.zst.sig"|"$repository_name.files.tar.zst"|"$repository_name.files.tar.zst.sig") ;;
        *) devario_repository_error "unexpected file in repository closure: $basename"; return 1 ;;
      esac
    fi
  done < <(find -P "$repo_dir" -mindepth 1 -maxdepth 1 -print0)

  for path in "${packages[@]}"; do
    package_name="$(bsdtar -xOf "$path" .PKGINFO \
      | awk -F ' = ' '$1 == "pkgname" { print $2; exit }')"
    if [[ -z "$package_name" || -n "${package_names[$package_name]:-}" ]]; then
      devario_repository_error "repository package names are missing or ambiguous: $(basename -- "$path")"
      return 1
    fi
    package_names["$package_name"]=1
    if [[ "$policy" == production ]]; then
      devario_is_plain_file "$path.sig" && [[ -s "$path.sig" ]] || {
        devario_repository_error "production package lacks a detached signature: $(basename -- "$path")"
        return 1
      }
      devario_gpgv_active_signature "$path.sig" "$path" || return 1
    fi
  done
  devario_inventory_packages expected_inventory "${packages[@]}" || return 1
  devario_inventory_database "$database" database_inventory || return 1
  devario_inventory_database "$files_database" files_inventory || return 1
  if [[ "$(printf '%s\n' "${expected_inventory[@]}")" \
    != "$(printf '%s\n' "${database_inventory[@]}")" \
    || "$(printf '%s\n' "${expected_inventory[@]}")" \
    != "$(printf '%s\n' "${files_inventory[@]}")" ]]; then
    devario_repository_error 'repository databases do not exactly describe the package artifact closure'
    return 1
  fi
  if (( repository_is_signed )); then
    devario_gpgv_active_signature "$database.sig" "$database" || return 1
    devario_gpgv_active_signature "$files_database.sig" "$files_database" || return 1
  fi
}
