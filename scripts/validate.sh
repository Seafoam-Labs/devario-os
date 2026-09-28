#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
base_profile_dir="$project_dir/iso"
edition_dir="$project_dir/editions/community"

usage() {
  cat <<'EOF'
Usage: ./scripts/validate.sh [--edition DIRECTORY]

Validate the core source tree and the profile composed with Community by
default, or with the strict edition contract rooted at DIRECTORY.
EOF
}

while (( $# )); do
  case "$1" in
    --edition)
      if (( $# < 2 )); then
        echo '--edition requires a directory argument.' >&2
        usage >&2
        exit 2
      fi
      edition_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$edition_dir" != /* ]]; then
  edition_dir="$project_dir/$edition_dir"
fi
if [[ ! -r "$script_dir/lib/edition.sh" ]]; then
  echo 'Validation error: the edition composition library is missing.' >&2
  exit 1
fi
# shellcheck source=lib/edition.sh
source "$script_dir/lib/edition.sh"

profile_dir="$(mktemp -d /tmp/devario-validation-profile.XXXXXX)"
cleanup_validation_profile() {
  rm -rf -- "$profile_dir"
}
trap cleanup_validation_profile EXIT
composition_identity_mode=normal
if [[ "${DEVARIO_VALIDATED_ACTION_SNAPSHOT:-0}" == 1 ]]; then
  composition_identity_mode=action-snapshot
fi
if ! devario_compose_profile \
  "$base_profile_dir" "$edition_dir" "$profile_dir" "$project_dir" "$composition_identity_mode"; then
  exit 1
fi

failed=0

fail() {
  echo "Validation error: $*" >&2
  failed=1
}

note() {
  echo "Note: $*"
}

required_files=(
  "$profile_dir/profile.json"
  "$profile_dir/packages.x86_64"
  "$profile_dir/shelly.build.conf"
  "$profile_dir/shelly.runtime.conf"
  "$profile_dir/airootfs/etc/calamares/settings.conf"
  "$profile_dir/airootfs/etc/calamares/modules/unpackfs.conf"
  "$profile_dir/airootfs/etc/calamares/modules/partition.conf"
  "$profile_dir/airootfs/etc/calamares/modules/limine.conf"
  "$profile_dir/airootfs/etc/calamares/modules/prepare_target.conf"
  "$profile_dir/airootfs/etc/calamares/modules/nvidia_preflight.conf"
  "$profile_dir/airootfs/etc/calamares/modules/nvidia.conf"
  "$profile_dir/airootfs/usr/lib/devario/configure-target-nvidia"
  "$profile_dir/airootfs/usr/share/devario/nvidia-supported-gpus.json"
  "$project_dir/tests/test-configure-target-nvidia.py"
  "$profile_dir/airootfs/etc/calamares/modules/services-systemd.conf"
  "$profile_dir/airootfs/etc/greetd/config.toml"
  "$profile_dir/airootfs/etc/polkit-1/rules.d/49-devario-live-installer.rules"
  "$profile_dir/airootfs/etc/systemd/system/default.target"
  "$profile_dir/airootfs/etc/systemd/system/devario-acceptance-self-check.service"
  "$profile_dir/airootfs/etc/systemd/system/multi-user.target.wants/devario-acceptance-self-check.service"
  "$profile_dir/airootfs/etc/systemd/system/shelly-keyring-init.service"
  "$profile_dir/airootfs/usr/lib/devario/acceptance-self-check"
  "$project_dir/packages/devario-boot/limine-update"
  "$profile_dir/airootfs/usr/lib/devario/prepare-target-kernel"
  "$profile_dir/airootfs/usr/local/bin/devario-aqueous-live-session"
  "$project_dir/packages/devario-boot/95-devario-boot.hook"
  "$profile_dir/airootfs/usr/share/calamares/branding/devario/branding.desc"
  "$profile_dir/late-airootfs/etc/skel/.bashrc"
  "$profile_dir/late-airootfs/usr/share/devario/fastfetch/config.jsonc"
  "$profile_dir/late-airootfs/usr/share/devario/fastfetch/devario-fish.txt"
  "$profile_dir/late-airootfs/usr/lib/sysusers.d/devario-live.conf"
  "$profile_dir/late-airootfs/usr/lib/tmpfiles.d/devario-live.conf"
  "$project_dir/packages/calamares/PKGBUILD"
  "$project_dir/packages/calamares/0001-devario-wayland-runtime.patch"
  "$project_dir/packages/ckbcomp/PKGBUILD"
  "$project_dir/packages/shelly/PKGBUILD"
  "$project_dir/packages/shelly/0001-remove-pacman-runtime-processes.patch"
  "$project_dir/packages/shelly/0002-support-alternate-alpm-config.patch"
  "$project_dir/packages/shelly/0003-use-shelly-runtime-paths.patch"
  "$project_dir/packages/devario-alpm-runtime/PKGBUILD"
  "$project_dir/packages/devario-base/PKGBUILD"
  "$project_dir/packages/devario-dracut/PKGBUILD"
  "$project_dir/packages/devario-boot/PKGBUILD"
  "$project_dir/packages/devario-boot/initramfs-update"
  "$project_dir/packages/devario-boot/boot-update"
  "$project_dir/tests/test-dracut-boot.sh"
  "$project_dir/tests/test-dracut-live-qemu.sh"
  "$project_dir/packages/linux-cachyos-lts/PKGBUILD"
  "$project_dir/packages/linux-cachyos-lts/config"
  "$project_dir/packages/linux-cachyos-lts/README.md"
  "$project_dir/packages/noctalia/PKGBUILD"
  "$project_dir/packages/noctalia/noctalia-50f0f095053a4b5c10874c4e7080f55dc15d3b38.tar.gz"
  "$project_dir/packages/noctalia-greeter/PKGBUILD"
  "$project_dir/packages/noctalia-greeter/noctalia-greeter-4aa960dcff874dddd4d3d94d931df43a416ea9cf.tar.gz"
  "$project_dir/packages/aqueous/PKGBUILD"
  "$project_dir/packages/aqueous/aqueous-001beb7d08ecb8e5b428b869dbb9351f8d97820c.tar.gz"
  "$project_dir/packages/aqueous/aqueous-zig-cache-001beb7d.tar.zst"
  "$project_dir/packages/aqueous/wlroots-0.20.2.tar.gz"
  "$project_dir/packages/aqueous/0001-devario-default-applications.patch"
  "$project_dir/packages/devario-aqueous-desktop/PKGBUILD"
  "$project_dir/packages/devario-aqueous-desktop/devario-gpu-driver.service"
  "$project_dir/packages/devario-aqueous-desktop/gpu-driver-setup"
  "$project_dir/packages/devario-aqueous-desktop/greetd-config.toml"
  "$project_dir/packages/devario-aqueous-desktop/greetd-gpu-driver.conf"
  "$project_dir/packages/devario-keyring/PKGBUILD"
  "$project_dir/packages/devario-keyring/devario.gpg"
  "$project_dir/packages/devario-keyring/devario-trusted"
  "$project_dir/packages/devario-keyring/devario-revoked"
  "$project_dir/scripts/init-repository-key.sh"
  "$project_dir/scripts/build-packages-nspawn.sh"
  "$project_dir/scripts/build-packages.sh"
  "$project_dir/scripts/build-iso-nspawn.sh"
  "$project_dir/scripts/build-iso.sh"
  "$project_dir/scripts/makepkg-shelly-adapter.sh"
  "$project_dir/scripts/makepkg-shelly.conf"
  "$project_dir/scripts/setup-qemu.sh"
  "$project_dir/scripts/lib/edition.sh"
  "$project_dir/scripts/compare-release-artifacts.sh"
  "$project_dir/scripts/test-image-boot.sh"
  "$project_dir/scripts/reject-secret-material.py"
  "$project_dir/scripts/render-release-os-release.py"
  "$project_dir/scripts/build-external-packages-nspawn.sh"
  "$project_dir/scripts/build-iso-controlled-nspawn.sh"
  "$project_dir/scripts/create-core-input-lock.sh"
  "$project_dir/scripts/verify-core-input-lock.sh"
  "$project_dir/scripts/core-input-lock.py"
  "$project_dir/scripts/verify-builder-attestation.sh"
  "$project_dir/scripts/verify-builder-attestation.py"
  "$project_dir/scripts/write-builder-attestation.sh"
  "$project_dir/scripts/write-builder-attestation.py"
  "$project_dir/scripts/verify-controlled-builder.sh"
  "$project_dir/scripts/verify-image-boundary.sh"
  "$project_dir/scripts/verify-repository-boundary.sh"
  "$project_dir/scripts/tree-closure-digest.py"
  "$project_dir/scripts/write-controlled-builder-manifest.py"
  "$project_dir/scripts/lib/repository.sh"
  "$project_dir/scripts/schemas/controlled-builder.schema.json"
  "$project_dir/scripts/schemas/core-input-lock.schema.json"
  "$project_dir/scripts/schemas/builder-attestation.schema.json"
  "$project_dir/scripts/schemas/image-build-record.schema.json"
  "$project_dir/scripts/validate-managed-action.sh"
  "$project_dir/release/source-manifest.json"
  "$project_dir/release/source-manifest.schema.json"
  "$project_dir/release/generate-release-metadata.sh"
  "$project_dir/release/generate-candidate-lock.sh"
  "$project_dir/release/validate-candidate-lock.sh"
  "$project_dir/release/generate-promotion-acceptance.sh"
  "$project_dir/release/validate-promotion-acceptance.sh"
  "$project_dir/release/generate-final-approval.sh"
  "$project_dir/release/validate-final-approval.sh"
  "$project_dir/release/promote-candidate.sh"
  "$project_dir/release/validate-promotion.sh"
  "$project_dir/release/approval-trust-policy.json"
  "$project_dir/release/approval-keyring/.gitkeep"
  "$project_dir/docs/RELEASE-POLICY.md"
  "$project_dir/docs/CORRESPONDING-SOURCE.md"
  "$project_dir/docs/IMAGE-ACCEPTANCE-MATRIX.md"
  "$project_dir/docs/PUBLIC-RELEASE-CHECKLIST.md"
  "$project_dir/.github/CODEOWNERS"
  "$project_dir/.github/workflows/validate.yml"
  "$project_dir/.github/actions/validate-managed/action.yml"
  "$project_dir/editions/community/package-sources.conf"
  "$project_dir/packages/devario-keyring/active-signer"
  "$project_dir/tests/fixtures/gpu-driver-setup/mock-modprobe"
  "$project_dir/tests/fixtures/makepkg-shelly/PKGBUILD"
  "$project_dir/tests/test-gpu-driver-setup.sh"
  "$project_dir/tests/test-prepare-target-kernel.sh"
  "$project_dir/tests/test-edition-composition.sh"
  "$project_dir/tests/test-release-metadata.sh"
  "$project_dir/tests/test-release-tree-symlinks.sh"
  "$project_dir/tests/test-candidate-lock.sh"
  "$project_dir/tests/test-reproducibility.sh"
  "$project_dir/tests/test-acceptance-self-check.sh"
  "$project_dir/tests/test-image-boot-harness.sh"
  "$project_dir/tests/test-promotion-acceptance.sh"
  "$project_dir/tests/test-final-approval.sh"
  "$project_dir/tests/test-promotion.sh"
  "$project_dir/tests/test-managed-action-contract.sh"
  "$project_dir/tests/test-secret-material.sh"
  "$project_dir/tests/test-repository-boundary.sh"
  "$project_dir/tests/test-repository-closure.sh"
  "$project_dir/tests/test-active-signer-trust.sh"
  "$project_dir/tests/test-development-key-rejection.sh"
  "$project_dir/tests/test-keyring-package-boundary.sh"
  "$project_dir/tests/test-release-identity.sh"
  "$project_dir/tests/test-core-input-lock-semantics.sh"
  "$project_dir/tests/test-controlled-builder-closure.sh"
  "$project_dir/tests/test-image-boundary.sh"
  "$project_dir/tests/test-shelly-storage-migration.sh"
)

for path in "${required_files[@]}"; do
  if [[ ! -f "$path" ]]; then
    fail "missing required file: ${path#"$project_dir/"}"
  fi
done

# Avoid cascading errors when a required input has not been created yet.
if (( failed )); then
  exit 1
fi

while IFS= read -r shell_file; do
  if ! bash -n "$shell_file"; then
    fail "shell syntax check failed: ${shell_file#"$project_dir/"}"
  fi
done < <(
  find "$project_dir/scripts" -maxdepth 1 -type f -name '*.sh' -print
  find "$project_dir/release" -maxdepth 1 -type f -name '*.sh' -print
  find "$project_dir/tests" -maxdepth 1 -type f -name '*.sh' -print
  find "$project_dir/packages" -mindepth 2 -maxdepth 2 -type f -name PKGBUILD -print
  printf '%s\n' "$project_dir/scripts/lib/edition.sh"
  printf '%s\n' "$profile_dir/late-airootfs/etc/skel/.bashrc"
  for boot_helper in kernel.sh kernel-command-line initramfs-update boot-update limine-update module-setup.sh live-root.sh install-root.sh verify-live-image; do
    printf '%s\n' "$project_dir/packages/devario-boot/$boot_helper"
  done
  printf '%s\n' "$profile_dir/airootfs/usr/lib/devario/prepare-target-kernel"
  printf '%s\n' "$profile_dir/airootfs/usr/lib/devario/acceptance-self-check"
  printf '%s\n' "$project_dir/packages/devario-aqueous-desktop/gpu-driver-setup"
  printf '%s\n' "$project_dir/tests/fixtures/gpu-driver-setup/mock-modprobe"
  printf '%s\n' "$project_dir/tests/test-gpu-driver-setup.sh"
  printf '%s\n' "$project_dir/tests/test-prepare-target-kernel.sh"
  printf '%s\n' "$project_dir/packages/devario-alpm-runtime/shelly-storage-migrate"
  printf '%s\n' "$project_dir/packages/devario-alpm-runtime/devario-alpm-runtime.install"
)

while IFS= read -r python_file; do
  if ! python3 -c 'import pathlib,sys; source=pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"); compile(source,sys.argv[1],"exec")' "$python_file"; then
    fail "Python syntax check failed: ${python_file#"$project_dir/"}"
  fi
done < <(find "$project_dir/release" "$project_dir/scripts" -maxdepth 1 -type f -name '*.py' -print | sort)

if ! bash "$project_dir/tests/test-gpu-driver-setup.sh"; then
  fail "GPU driver setup behavior tests failed"
fi
if ! DEVARIO_PROFILE_DIR="$profile_dir" \
  python3 "$project_dir/tests/test-configure-target-nvidia.py"; then
  fail "Calamares NVIDIA installation behavior tests failed"
fi
if ! DEVARIO_PROFILE_DIR="$profile_dir" \
  bash "$project_dir/tests/test-prepare-target-kernel.sh"; then
  fail "target-kernel preparation behavior tests failed"
fi
if ! bash "$project_dir/tests/test-dracut-boot.sh"; then
  fail "Devario dracut behavior tests failed"
fi
if ! bash "$project_dir/tests/test-edition-composition.sh"; then
  fail "edition composition behavior tests failed"
fi
for release_test in \
  test-release-metadata.sh \
  test-release-tree-symlinks.sh \
  test-candidate-lock.sh \
  test-reproducibility.sh \
  test-acceptance-self-check.sh \
  test-image-boot-harness.sh \
  test-promotion-acceptance.sh \
  test-final-approval.sh \
  test-promotion.sh \
  test-managed-action-contract.sh; do
  if ! bash "$project_dir/tests/$release_test"; then
    fail "release contract test failed: $release_test"
  fi
done
for boundary_test in \
  test-secret-material.sh \
  test-repository-boundary.sh \
  test-repository-closure.sh \
  test-active-signer-trust.sh \
  test-development-key-rejection.sh \
  test-keyring-package-boundary.sh \
  test-release-identity.sh \
  test-core-input-lock-semantics.sh \
  test-controlled-builder-closure.sh \
  test-image-boundary.sh \
  test-shelly-storage-migration.sh; do
  if ! bash "$project_dir/tests/$boundary_test"; then
    fail "controlled-build/boundary test failed: $boundary_test"
  fi
done

if ! python3 -c 'import jsonschema' >/dev/null 2>&1; then
  fail 'python3-jsonschema is required for Draft 2020-12 release validation'
else
  while IFS= read -r schema_file; do
    if ! python3 -c \
      'import json,sys
from jsonschema.validators import validator_for
def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate object key: {key}")
        result[key] = value
    return result
with open(sys.argv[1], encoding="utf-8") as stream:
    schema = json.load(stream, object_pairs_hook=strict_object)
validator = validator_for(schema)
validator.check_schema(schema)' \
      "$schema_file"; then
      fail "invalid JSON Schema: ${schema_file#"$project_dir/"}"
    fi
  done < <(find "$project_dir/release" "$project_dir/scripts/schemas" -type f -name '*.schema.json' -print | sort)
  if ! python3 "$project_dir/release/validate-json.py" \
    "$project_dir/release/source-manifest.schema.json" \
    "$project_dir/release/source-manifest.json"; then
    fail 'release/source-manifest.json failed strict schema validation'
  fi
  if ! python3 "$project_dir/release/validate-json.py" \
    "$project_dir/release/trust-policy.schema.json" \
    "$project_dir/release/approval-trust-policy.json"; then
    fail 'release/approval-trust-policy.json failed strict schema validation'
  fi
fi

secret_scan_args=(--tree "$project_dir")
if [[ -d "$project_dir/.git" ]]; then secret_scan_args=(--git-tracked "$project_dir"); fi
if ! python3 "$project_dir/scripts/reject-secret-material.py" "${secret_scan_args[@]}"; then
  fail 'tracked source contains forbidden private-key material'
fi

while IFS= read -r action_use; do
  action_ref="${action_use##*@}"
  if [[ "$action_use" != uses:*./* && ! "$action_ref" =~ ^[0-9a-f]{40}$ ]]; then
    fail "GitHub Action is not pinned to a full commit ID: $action_use"
  fi
done < <(grep -RhoE 'uses:[[:space:]]+[^[:space:]#]+' "$project_dir/.github")

duplicates="$(sed -E '/^[[:space:]]*(#|$)/d' "$profile_dir/packages.x86_64" | sort | uniq -d)"
if [[ -n "$duplicates" ]]; then
  fail "duplicate package entries: ${duplicates//$'\n'/, }"
fi

package_is_listed() {
  grep -Eq "^[[:space:]]*$1[[:space:]]*$" "$profile_dir/packages.x86_64"
}

for required_package in \
  aqueous aqueous-session aqueous-noctalia \
  calamares ckbcomp devario-alpm-runtime devario-aqueous-desktop \
  devario-base devario-boot devario-dracut devario-keyring greetd limine noctalia noctalia-greeter shelly fastfetch \
  linux-cachyos-lts linux-cachyos-lts-headers nvidia-open-dkms nvidia-utils \
  vulkan-intel vulkan-radeon vulkan-swrast xorg-xwayland; do
  if ! package_is_listed "$required_package"; then
    fail "packages.x86_64 does not include $required_package"
  fi
done

for forbidden_package in \
  mkinitcpio mkinitcpio-archiso pacman base linux grub os-prober lightdm lightdm-gtk-greeter xfce4 xfce4-goodies \
  xorg-server xorg-xinit greetd-agreety greetd-tuigreet vulkan-nouveau; do
  if package_is_listed "$forbidden_package"; then
    fail "packages.x86_64 must not include $forbidden_package"
  fi
done

declare -A expected_pkgnames=(
  [calamares]=calamares
  [ckbcomp]=ckbcomp
  [shelly]=shelly
  [devario-alpm-runtime]=devario-alpm-runtime
  [devario-aqueous-desktop]=devario-aqueous-desktop
  [devario-filesystem]=devario-filesystem
  [seafoam-keyring]=seafoam-keyring
  [shelly-arch-compat]=shelly-arch-compat
  [devario-base]=devario-base
  [devario-boot]=devario-boot
  [devario-dracut]=devario-dracut
  [devario-keyring]=devario-keyring
  [linux-cachyos-lts]=linux-cachyos-lts
  [noctalia]=noctalia
  [noctalia-greeter]=noctalia-greeter
  [aqueous]=aqueous
)

for package_dir_name in "${!expected_pkgnames[@]}"; do
  expected_pkgname="${expected_pkgnames[$package_dir_name]}"
  pkgbuild="$project_dir/packages/$package_dir_name/PKGBUILD"
  if [[ "$package_dir_name" == aqueous ]]; then
    if ! grep -Eq '^[[:space:]]*pkgbase=aqueous[[:space:]]*$' "$pkgbuild"; then
      fail "aqueous/PKGBUILD does not declare pkgbase=aqueous"
    fi
    for split_pkgname in aqueous aqueous-session aqueous-noctalia; do
      if ! grep -Fq "'$split_pkgname'" "$pkgbuild"; then
        fail "aqueous/PKGBUILD does not declare split package $split_pkgname"
      fi
    done
  elif [[ "$package_dir_name" == linux-cachyos-lts ]]; then
    if ! grep -Fqx 'pkgbase="linux-$_pkgsuffix"' "$pkgbuild" \
      || ! grep -Fqx 'pkgname=("$pkgbase")' "$pkgbuild"; then
      fail "linux-cachyos-lts/PKGBUILD does not declare its kernel split package"
    fi
  elif ! grep -Eq "^[[:space:]]*pkgname=['\"]?${expected_pkgname}['\"]?[[:space:]]*$" "$pkgbuild"; then
    fail "$package_dir_name/PKGBUILD does not declare pkgname=$expected_pkgname"
  fi
done

kernel_pkgbuild="$project_dir/packages/linux-cachyos-lts/PKGBUILD"
kernel_config="$project_dir/packages/linux-cachyos-lts/config"
expected_kernel_config_b2='81fafd3adcaf3b690d8d4791693e68c7ae921d103ebfd70e8d0ae15cd05ecde5e6672ae43c3a7875686d883c1f5b82d2c8b37b40aee8dcb0563913f9dd6469b6'
actual_kernel_config_b2="$(b2sum "$kernel_config")"
actual_kernel_config_b2="${actual_kernel_config_b2%% *}"
if [[ "$actual_kernel_config_b2" != "$expected_kernel_config_b2" ]]; then
  fail "linux-cachyos-lts/config failed its pinned BLAKE2 checksum"
fi
for required_kernel_recipe_text in \
  '972d31fe2cbfda19208501a9518152ab90cfa2cc' \
  '_processor_opt=generic_v1' \
  '_major=6.18' \
  '_minor=42' \
  ': "${_build_nvidia_open:=no}"' \
  'pkgrel=1.2' \
  'pkgname+=("$pkgbase-headers")' \
  'KBUILD_BUILD_HOST=devario' \
  'e322057f183bf666741ec12d2d64f681d9ba7bc4e4326354656ca23be5ecfb5ab3ab2ef494ddb54605f4ff1d5bba5a08493760eea9a36860080eafdb369a0321' \
  '"$modulesdir/devario-kernel"' \
  "$expected_kernel_config_b2"; do
  if ! grep -Fq "$required_kernel_recipe_text" "$kernel_pkgbuild"; then
    fail "linux-cachyos-lts packaging is missing: $required_kernel_recipe_text"
  fi
done
if grep -Eq "^[[:space:]]*['\"]?SKIP['\"]?([[:space:]]|$)" "$kernel_pkgbuild" \
  || grep -Fq '_processor_opt:=}' "$kernel_pkgbuild"; then
  fail "linux-cachyos-lts must use pinned sources and an unconditional baseline CPU target"
fi

for ckbcomp_dependency in perl xkeyboard-config; do
  if ! grep -Eq "['\"]${ckbcomp_dependency}([<>=][^'\"]*)?['\"]" \
    "$project_dir/packages/ckbcomp/PKGBUILD"; then
    fail "ckbcomp must depend on $ckbcomp_dependency"
  fi
done

if ! grep -Eq "['\"]ckbcomp([<>=][^'\"]*)?['\"]" \
  "$project_dir/packages/calamares/PKGBUILD"; then
  fail "Calamares must depend on Devario's ckbcomp package"
fi

calamares_pkgbuild="$project_dir/packages/calamares/PKGBUILD"
calamares_runtime_patch="$project_dir/packages/calamares/0001-devario-wayland-runtime.patch"
for required_calamares_patch_text in \
  'm_configureXkb = isX11;' \
  'QStandardPaths::findExecutable( "os-prober" ).isEmpty()' \
  'os-prober is not installed; skipping optional operating-system discovery.'; do
  if ! grep -Fq "$required_calamares_patch_text" "$calamares_runtime_patch"; then
    fail "the Calamares runtime patch is missing: $required_calamares_patch_text"
  fi
done
if ! grep -Fq "'0001-devario-wayland-runtime.patch'" "$calamares_pkgbuild" \
  || ! grep -Fq 'patch -d "$srcdir/${pkgname}-${pkgver}" -Np1' \
    "$calamares_pkgbuild"; then
  fail "the Calamares package does not apply the Devario runtime patch"
fi

declare -A pinned_desktop_sources=(
  ["packages/noctalia/noctalia-50f0f095053a4b5c10874c4e7080f55dc15d3b38.tar.gz"]='bcc34b2cfcb3650fa4e0197625c88918d5411c8a1532b9652497e205e491217c'
  ["packages/noctalia-greeter/noctalia-greeter-4aa960dcff874dddd4d3d94d931df43a416ea9cf.tar.gz"]='4e42a6056037efe6f9b162c8341d7a0514a49595e30fec2098c05ffb1b993af6'
  ["packages/aqueous/aqueous-001beb7d08ecb8e5b428b869dbb9351f8d97820c.tar.gz"]='0f17fa6457b966354ed22c724777961f853d99dc68bf255f27b1fd02f0667c84'
  ["packages/aqueous/aqueous-zig-cache-001beb7d.tar.zst"]='b2495e18a20391446189f44d3eff762845c4883da78b7042ba99fdd10189b310'
  ["packages/aqueous/wlroots-0.20.2.tar.gz"]='972c7ac44b17828f4702bfae7cd8347346a3fb5b2c1076cfa2c3fcedac5ec343'
  ["packages/aqueous/0001-devario-default-applications.patch"]='096170a6d8fdd2e582b6a0a0b95ee26988094934d1a622ea1f04321bf341027d'
  ["packages/devario-aqueous-desktop/devario-gpu-driver.service"]='5eaa5d9565feaf0b0447b0ff91bf1c1082c56740edd37968d25b09c518294470'
  ["packages/devario-aqueous-desktop/gpu-driver-setup"]='533cfa381f0d7eb1ef1e5da15037992fd5f59c539cfe6d4a8f14e6d6d3aeb99f'
  ["packages/devario-aqueous-desktop/greetd-config.toml"]='16afecd6b0f64351c92ed780d1cdb5d3efa1e793b679da5dde98bb39a124e7d7'
  ["packages/devario-aqueous-desktop/greetd-gpu-driver.conf"]='a997663d00e362e780c6d29989bcb9dfdb50d5b00142322bee207d68be8c3801'
)
for pinned_path in "${!pinned_desktop_sources[@]}"; do
  actual_sha256="$(sha256sum "$project_dir/$pinned_path")"
  actual_sha256="${actual_sha256%% *}"
  if [[ "$actual_sha256" != "${pinned_desktop_sources[$pinned_path]}" ]]; then
    fail "$pinned_path failed its pinned SHA-256 checksum"
  fi
done

for desktop_recipe in noctalia noctalia-greeter aqueous devario-aqueous-desktop; do
  if grep -Eq "^[[:space:]]*['\"]?SKIP['\"]?([[:space:]]|$)" \
    "$project_dir/packages/$desktop_recipe/PKGBUILD"; then
    fail "$desktop_recipe contains an unchecked source"
  fi
done

for pinned_revision in \
  50f0f095053a4b5c10874c4e7080f55dc15d3b38 \
  4aa960dcff874dddd4d3d94d931df43a416ea9cf \
  001beb7d08ecb8e5b428b869dbb9351f8d97820c; do
  if ! grep -R -Fq "$pinned_revision" \
    "$project_dir/packages/noctalia/PKGBUILD" \
    "$project_dir/packages/noctalia-greeter/PKGBUILD" \
    "$project_dir/packages/aqueous/PKGBUILD"; then
    fail "desktop package metadata is missing pinned revision $pinned_revision"
  fi
done

aqueous_pkgbuild="$project_dir/packages/aqueous/PKGBUILD"
for required_aqueous_build_text in \
  'AQUEOUS_WLROOTS_CACHE_DIR="$srcdir"' \
  'ZIG_GLOBAL_CACHE_DIR="$srcdir"' \
  '-Dcpu=baseline' \
  '-Doptimize=ReleaseSafe' \
  '-Dxwayland' \
  '-Dllvm' \
  '-Dman-pages=true' \
  'noctalia plugins lint'; do
  if ! grep -Fq -- "$required_aqueous_build_text" "$aqueous_pkgbuild"; then
    fail "Aqueous packaging is missing: $required_aqueous_build_text"
  fi
done
if ! grep -Fq 'spawn:firefox' \
  "$project_dir/packages/aqueous/0001-devario-default-applications.patch" \
  || ! grep -Fq 'spawn:pkexec calamares' \
    "$project_dir/packages/aqueous/0001-devario-default-applications.patch"; then
  fail "Aqueous defaults must expose Firefox and the live Calamares installer"
fi

if command -v bsdtar >/dev/null 2>&1; then
  zig_cache_listing="$(
    bsdtar -tf "$project_dir/packages/aqueous/aqueous-zig-cache-001beb7d.tar.zst"
  )"
  for zig_dependency in pixman wayland wlroots xkbcommon translate_c aro; do
    if ! grep -Eq "^p/${zig_dependency}-" <<< "$zig_cache_listing"; then
      fail "the offline Aqueous Zig cache is missing $zig_dependency"
    fi
  done

  aqueous_source="$project_dir/packages/aqueous/aqueous-001beb7d08ecb8e5b428b869dbb9351f8d97820c.tar.gz"
  aqueous_desktop_entry="$(
    bsdtar -xOf "$aqueous_source" aqueous-0.4.6/aqueous.desktop
  )"
  aqueous_wm_wrapper="$(
    bsdtar -xOf "$aqueous_source" aqueous-0.4.6/packaging/aqueous-wm.sh
  )"
  aqueous_init_wrapper="$(
    bsdtar -xOf "$aqueous_source" aqueous-0.4.6/packaging/aqueous-init
  )"
  if ! grep -Fxq 'Exec=uwsm start -- aqueous-wm' <<< "$aqueous_desktop_entry" \
    || ! grep -Fxq 'TryExec=uwsm' <<< "$aqueous_desktop_entry" \
    || ! grep -Fxq 'DesktopNames=Aqueous' <<< "$aqueous_desktop_entry"; then
    fail "the pinned Aqueous Wayland session does not use UWSM"
  fi
  if ! grep -Fq '/usr/bin/aqueous -c /usr/bin/aqueous-init' <<< "$aqueous_wm_wrapper" \
    || ! grep -Fq 'uwsm finalize' <<< "$aqueous_init_wrapper" \
    || ! grep -Fq 'graphical-session.target' <<< "$aqueous_init_wrapper"; then
    fail "the pinned Aqueous source lacks the required UWSM session lifecycle"
  fi

  greeter_source="$project_dir/packages/noctalia-greeter/noctalia-greeter-4aa960dcff874dddd4d3d94d931df43a416ea9cf.tar.gz"
  greeter_source_listing="$(bsdtar -tf "$greeter_source")"
  for greeter_source_path in \
    noctalia-greeter-1.0.0/assets/noctalia.svg \
    noctalia-greeter-1.0.0/scripts/noctalia-greeter-session \
    noctalia-greeter-1.0.0/data/tmpfiles.d/noctalia-greeter.conf; do
    if ! grep -Fxq "$greeter_source_path" <<< "$greeter_source_listing"; then
      fail "the pinned Noctalia Greeter source is missing $greeter_source_path"
    fi
  done
fi

for greeter_dependency in greetd wlroots0.20 dbus; do
  if ! grep -Eq "['\"]${greeter_dependency}([<>=][^'\"]*)?['\"]" \
    "$project_dir/packages/noctalia-greeter/PKGBUILD"; then
    fail "Noctalia Greeter must depend on $greeter_dependency"
  fi
done
if grep -Eq "^[[:space:]]*conflicts=.*['\"]greetd-agreety['\"]" \
  "$project_dir/packages/noctalia-greeter/PKGBUILD"; then
  fail "Noctalia Greeter must coexist with greetd's required agreety fallback"
fi
if ! grep -Fq -- '--buildtype=plain' \
  "$project_dir/packages/noctalia-greeter/PKGBUILD"; then
  fail "Noctalia Greeter must use a portable non-native Meson build type"
fi

desktop_meta="$project_dir/packages/devario-aqueous-desktop/PKGBUILD"
for desktop_dependency in \
  aqueous aqueous-session aqueous-noctalia noctalia noctalia-greeter greetd \
  linux-cachyos-lts-headers nvidia-open-dkms nvidia-utils; do
  if ! grep -Eq "['\"]${desktop_dependency}([<>=][^'\"]*)?['\"]" "$desktop_meta"; then
    fail "the Devario desktop metapackage must depend on $desktop_dependency"
  fi
done
if grep -Eq "['\"]vulkan-nouveau([<>=][^'\"]*)?['\"]" "$desktop_meta"; then
  fail "the NVIDIA-only desktop metapackage must not depend on vulkan-nouveau"
fi

gpu_driver_setup="$project_dir/packages/devario-aqueous-desktop/gpu-driver-setup"
gpu_driver_unit="$project_dir/packages/devario-aqueous-desktop/devario-gpu-driver.service"
gpu_driver_dropin="$project_dir/packages/devario-aqueous-desktop/greetd-gpu-driver.conf"
for required_gpu_setup_text in \
  '"$vendor" == 0x10de' \
  '"$class" == 0x03*' \
  '"$modprobe_command" nvidia_drm modeset=1' \
  'write_state unavailable'; do
  if ! grep -Fq "$required_gpu_setup_text" "$gpu_driver_setup"; then
    fail "the Devario GPU setup helper is missing: $required_gpu_setup_text"
  fi
done
if grep -Eq 'modprobe_command.*nouveau|modprobe[[:space:]]+nouveau' \
  "$gpu_driver_setup"; then
  fail "the NVIDIA setup helper must not bypass nvidia-utils' Nouveau blacklist"
fi
if ! grep -Fxq 'Before=greetd.service' "$gpu_driver_unit" \
  || ! grep -Fxq 'ExecStart=/usr/lib/devario/gpu-driver-setup --setup' \
    "$gpu_driver_unit"; then
  fail "the NVIDIA setup service must complete before greetd"
fi
for required_gpu_dropin_text in \
  'Wants=devario-gpu-driver.service' \
  'After=devario-gpu-driver.service'; do
  if ! grep -Fxq "$required_gpu_dropin_text" "$gpu_driver_dropin"; then
    fail "the greetd GPU setup dependency is missing: $required_gpu_dropin_text"
  fi
done
if find "$profile_dir" "$project_dir/packages" -type f \
  -path '*/modprobe.d/nvidia-utils.conf' -print -quit | grep -q .; then
  fail "Devario must not override nvidia-utils' Nouveau blacklist"
fi

if ! grep -Eq "['\"]libalpm\\.so=16-64['\"]" \
  "$project_dir/packages/shelly/PKGBUILD"; then
  fail "Shelly must depend on the libalpm.so.16 ABI"
fi

if ! grep -Fxq 'pkgver=3.1.6' "$project_dir/packages/shelly/PKGBUILD"; then
  fail "the Community Shelly package must track upstream 3.1.6"
fi
if ! grep -Fxq '_commit=d9d89773968a5a03beb5183c1101e0235e4f3524' \
  "$project_dir/packages/shelly/PKGBUILD" \
  || ! grep -Fq \
    "'025329c8972e592b72fa7955bd6cea76ddd723278a9dfa148b83cae4f999c923'" \
    "$project_dir/packages/shelly/PKGBUILD"; then
  fail "Shelly 3.1.6 must be pinned to its verified release commit archive"
fi

if grep -Eq "['\"]pacman([<>=][^'\"]*)?['\"]" \
  "$project_dir/packages/shelly/PKGBUILD"; then
  fail "Shelly must not depend on or provide the pacman package"
fi

if ! grep -Fq "'0001-remove-pacman-runtime-processes.patch'" \
  "$project_dir/packages/shelly/PKGBUILD" \
  || ! grep -Fq '/usr/bin/shelly-key' \
    "$project_dir/packages/shelly/0001-remove-pacman-runtime-processes.patch" \
  || ! grep -Fq 'Shelly.Cli.Zig/src/commands/repository.zig' \
    "$project_dir/packages/shelly/0001-remove-pacman-runtime-processes.patch" \
  || ! grep -Fq 'sectionContains(files, "%FILES%", member_path)' \
    "$project_dir/packages/shelly/0001-remove-pacman-runtime-processes.patch" \
  || ! grep -Fq \
    "'5f40ba156149bf1abf6b3b226cd3c25b07711a077cf593cd2e6e12fa1a42cc89'" \
    "$project_dir/packages/shelly/PKGBUILD"; then
  fail "Shelly must patch its remaining Pacman executable calls to native helpers"
fi

if ! grep -Fq "'0002-support-alternate-alpm-config.patch'" \
  "$project_dir/packages/shelly/PKGBUILD" \
  || ! grep -Fq 'SHELLY_ALPM_CONFIG' \
    "$project_dir/packages/shelly/0002-support-alternate-alpm-config.patch" \
  || ! grep -Fq \
    "'55310d154dbcff483e21e0953c7b679ce1a699ec14b09ba58b374d2aecf7922e'" \
    "$project_dir/packages/shelly/PKGBUILD"; then
  fail "Shelly must provide checksummed alternate ALPM config support"
fi
if ! grep -Fq "'0003-use-shelly-runtime-paths.patch'" \
  "$project_dir/packages/shelly/PKGBUILD" \
  || ! grep -Fq '/etc/shelly.conf' \
    "$project_dir/packages/shelly/0003-use-shelly-runtime-paths.patch" \
  || ! grep -Fq '/var/lib/shelly' \
    "$project_dir/packages/shelly/0003-use-shelly-runtime-paths.patch" \
  || ! grep -Fq \
    "'4f3ddd6dd229433a71263c7a0ed9f0f6690d676e0ec0e45f03bfee81bcc443d7'" \
    "$project_dir/packages/shelly/PKGBUILD"; then
  fail "Shelly must provide checksummed Shelly-owned runtime path defaults"
fi
if ! grep -Fq 'Shelly.Cli.Zig/src/commands/builder.zig' \
  "$project_dir/packages/shelly/0003-use-shelly-runtime-paths.patch" \
  || ! grep -Fq 'Shelly.PackageManager/src/aur/builder/package_file.zig' \
    "$project_dir/packages/shelly/0003-use-shelly-runtime-paths.patch" \
  || ! grep -Fq 'Isolated root provisioning is unavailable on Devario' \
    "$project_dir/packages/shelly/0003-use-shelly-runtime-paths.patch"; then
  fail "Shelly's native builder must use Devario paths and reject legacy isolated provisioning"
fi
if ! grep -Fq "backup=('etc/shellybuild.conf')" \
  "$project_dir/packages/shelly/PKGBUILD" \
  || grep -Eq "['\"]arch-install-scripts([<>=][^'\"]*)?['\"]" \
    "$project_dir/packages/shelly/PKGBUILD"; then
  fail "Shelly must package its builder policy without enabling legacy isolated provisioning"
fi

makepkg_adapter="$project_dir/scripts/makepkg-shelly-adapter.sh"
makepkg_config="$project_dir/scripts/makepkg-shelly.conf"
package_build_script="$project_dir/scripts/build-packages.sh"

if [[ ! -x "$makepkg_adapter" ]]; then
  fail "the strict makepkg Shelly adapter must be executable"
fi
if ! grep -Fq '[[ "$1" != -Qi ]]' "$makepkg_adapter" \
  || ! grep -Fq 'shelly list standard --show-hidden --json' "$makepkg_adapter"; then
  fail "the makepkg adapter must serve only its read-only inventory query through Shelly"
fi
if "$makepkg_adapter" -T bash >/dev/null 2>&1; then
  fail "the makepkg adapter accepted a dependency-resolution query"
else
  adapter_rejection_status=$?
  if (( adapter_rejection_status != 64 )); then
    fail "the makepkg adapter did not reject -T with its strict status"
  fi
fi

if ! grep -Fq "OPTIONS+=('!autodeps')" "$makepkg_config"; then
  fail "the dedicated makepkg config must disable automatic dependency queries"
fi
if ! grep -Fq 'PACMAN="$makepkg_adapter" makepkg --config "$makepkg_config"' \
  "$package_build_script" \
  || ! grep -Fq 'build_args=(--clean --cleanbuild --force --noconfirm --nodeps)' \
    "$package_build_script"; then
  fail "every package archive build must use --nodeps and the strict Shelly adapter"
fi
if grep -Eq -- '--(syncdeps|rmdeps|install)([=[:space:]]|$)' "$package_build_script"; then
  fail "build-packages.sh enables a makepkg mode that can bypass the Shelly adapter"
fi
for shelly_build_call in \
  'shelly sync standard --no-confirm' \
  'shelly install standard --no-confirm'; do
  if ! grep -Fq "$shelly_build_call" "$package_build_script"; then
    fail "build-packages.sh is missing: $shelly_build_call"
  fi
done
for desktop_build_package in linux-cachyos-lts noctalia noctalia-greeter aqueous devario-aqueous-desktop; do
  if ! grep -Eq "^[[:space:]]+${desktop_build_package}[[:space:]]*$" \
    "$package_build_script"; then
    fail "build-packages.sh omits $desktop_build_package from its package order"
  fi
done
for selective_build_text in \
  'selected_package_order=()' \
  'for package_name in "${selected_package_order[@]}"' \
  'Unknown package directory: $package_name'; do
  if ! grep -Fq "$selective_build_text" "$package_build_script"; then
    fail "build-packages.sh is missing selective-build support: $selective_build_text"
  fi
done
if ! grep -Fq './scripts/build-packages.sh "${requested_packages[@]}"' \
  "$project_dir/scripts/build-packages-nspawn.sh"; then
  fail "the nspawn package builder does not forward selective package builds"
fi
if ! grep -Fq "awk -F ' = ' '/^pkgname = / { print \$2 }'" \
  "$package_build_script"; then
  fail "build-packages.sh must recognize every name produced by a split package"
fi
for required_repository_cleanup_text in \
  'bsdtar -xOf "$artifact" .PKGINFO' \
  'built_artifact_basenames["$artifact_basename"]=1' \
  'unsigned_basename="${repository_basename%.sig}"'; do
  if ! grep -Fq "$required_repository_cleanup_text" "$package_build_script"; then
    fail "build-packages.sh does not remove superseded package artifacts safely"
  fi
done
if ! grep -Fq 'if [[ "$package_name" == noctalia ]]' "$package_build_script" \
  || ! grep -Fq 'shelly install standard --no-confirm "${artifacts[@]}"' \
    "$package_build_script"; then
  fail "the pinned Noctalia build must be installed through Shelly before Aqueous validation"
fi

if command -v makepkg >/dev/null 2>&1; then
  makepkg_metadata_root="$(mktemp -d /tmp/devario-makepkg-metadata.XXXXXX)"
  mkdir -p "$makepkg_metadata_root/packages" "$makepkg_metadata_root/sources" "$makepkg_metadata_root/build"
  for package_dir_name in "${!expected_pkgnames[@]}"; do
    if ! (
      cd "$project_dir/packages/$package_dir_name"
      DEVARIO_MAKEPKG_PKGDEST="$makepkg_metadata_root/packages" \
      DEVARIO_MAKEPKG_SRCPKGDEST="$makepkg_metadata_root/sources" \
      DEVARIO_MAKEPKG_BUILDDIR="$makepkg_metadata_root/build" \
      PACMAN="$makepkg_adapter" makepkg --config "$makepkg_config" \
        --printsrcinfo >/dev/null
    ); then
      fail "$package_dir_name/PKGBUILD failed makepkg metadata validation"
    fi
  done
  rm -rf -- "$makepkg_metadata_root"

  if command -v strace >/dev/null 2>&1; then
    makepkg_trace_dir="$(mktemp -d /tmp/devario-makepkg-trace.XXXXXX)"
    makepkg_trace="$makepkg_trace_dir/execve.log"
    makepkg_trace_stderr="$makepkg_trace_dir/strace.stderr"
    if ! PACMAN="$makepkg_adapter" \
      DEVARIO_MAKEPKG_PKGDEST="$makepkg_trace_dir/packages" \
      DEVARIO_MAKEPKG_SRCPKGDEST="$makepkg_trace_dir/sources" \
      DEVARIO_MAKEPKG_BUILDDIR="$makepkg_trace_dir/build" \
      PKGDEST="$makepkg_trace_dir/packages" \
      BUILDDIR="$makepkg_trace_dir/build" \
      SRCDEST="$makepkg_trace_dir/sources" \
      strace -f -qq -s 4096 -e trace=execve -o "$makepkg_trace" \
        makepkg --config "$makepkg_config" --nodeps --force --noconfirm \
          --nosign -D "$project_dir/tests/fixtures/makepkg-shelly" \
          >/dev/null 2>"$makepkg_trace_stderr"; then
      if grep -Fq 'Operation not permitted' "$makepkg_trace_stderr"; then
        note "ptrace is restricted; the makepkg execve regression probe was skipped."
      else
        sed -n '1,20p' "$makepkg_trace_stderr" >&2
        fail "the traced makepkg Shelly-adapter probe failed"
      fi
    elif grep -Eq \
      'execve\("([^"]*/)?(pacman|pacman-key|pacman-conf|pacstrap)"' \
      "$makepkg_trace"; then
      fail "makepkg executed a forbidden package-manager process"
    elif ! grep -Eq 'execve\("([^"]*/)?shelly"' "$makepkg_trace"; then
      fail "the makepkg inventory trace did not execute Shelly"
    fi
    rm -rf -- "$makepkg_trace_dir"
  else
    note "strace is unavailable; the makepkg execve regression probe was skipped."
  fi
else
  note "makepkg is unavailable; PKGBUILD metadata linting was skipped."
fi

if ! grep -Eq "['\"]libalpm\.so([<>=][^'\"]*)?['\"]" \
  "$project_dir/packages/devario-alpm-runtime/PKGBUILD"; then
  fail "devario-alpm-runtime must provide the libalpm.so dependency"
fi

if ! grep -Eq '^[[:space:]]*provides=.*pacman=.*pkgver' \
  "$project_dir/packages/devario-alpm-runtime/PKGBUILD"; then
  fail "devario-alpm-runtime must provide a versioned Pacman compatibility edge"
fi

for replacement_field in conflicts replaces; do
  if ! grep -Eq "^[[:space:]]*${replacement_field}=.*['\"]pacman['\"]" \
    "$project_dir/packages/devario-alpm-runtime/PKGBUILD"; then
    fail "devario-alpm-runtime must declare ${replacement_field}=pacman"
  fi
done

if grep -Eq "^[[:space:]]*['\"]pacman([<>=][^'\"]*)?['\"][[:space:]]*$" \
  <(sed -n '/^[[:space:]]*depends=(/,/^[[:space:]]*)/p' \
    "$project_dir/packages/devario-alpm-runtime/PKGBUILD"); then
  fail "devario-alpm-runtime must not depend on the real pacman package"
fi

for base_dependency in shelly devario-alpm-runtime; do
  if ! grep -Eq "['\"]${base_dependency}([<>=][^'\"]*)?['\"]" \
    "$project_dir/packages/devario-base/PKGBUILD"; then
    fail "devario-base must depend on $base_dependency"
  fi
done

if grep -Eq "['\"]pacman([<>=][^'\"]*)?['\"]" \
  "$project_dir/packages/devario-base/PKGBUILD"; then
  fail "devario-base must not depend on or provide pacman"
fi

for runtime_placeholder in \
  '@DEVARIO_CORE_RUNTIME_SIGLEVEL@' \
  '@DEVARIO_CORE_RUNTIME_REPO@' \
  '@DEVARIO_MANAGED_RUNTIME_REPOSITORY@'; do
  if ! grep -Fq "$runtime_placeholder" "$profile_dir/shelly.runtime.conf"; then
    fail "shelly.runtime.conf is missing placeholder $runtime_placeholder"
  fi
done

for alpm_config in \
  "$profile_dir/shelly.build.conf" \
  "$profile_dir/shelly.runtime.conf" \
  "$project_dir/packages/devario-alpm-runtime/shelly.conf"; do
  if grep -Eq '^\[cachyos([^]]*)?\]$' "$alpm_config"; then
    fail "${alpm_config#"$project_dir/"} must not require a CachyOS binary repository"
  fi
done

if ! grep -Fq 'DEVARIO_CORE_REPO_URL' "$project_dir/scripts/build-iso.sh" \
  || ! grep -Fq 'devario_validate_https_url "$core_runtime_url"' "$project_dir/scripts/build-iso.sh"; then
  fail "release ISO builds must require an explicit credential-free HTTPS core repository"
fi

iso_nspawn_script="$project_dir/scripts/build-iso-nspawn.sh"
for required_nspawn_iso_text in \
  '--release-version' \
  'build-iso-controlled-nspawn.sh' \
  '"$script_dir/build-packages-nspawn.sh" --prepare-only' \
  'run_container_root /usr/bin/shelly install standard --no-confirm' \
  'DEVARIO_WORK_DIR cannot be host-bound by the nspawn wrapper.' \
  '/usr/bin/mktemp -d /var/tmp/devario-iso.XXXXXX' \
  'devario-iso-build.log' \
  'build_pipeline_status=("${PIPESTATUS[@]}")' \
  'tail -n 200 "$build_log"' \
  '--capability=CAP_SYS_ADMIN,CAP_MKNOD' \
  './scripts/build-iso.sh'; do
  if ! grep -Fq -- "$required_nspawn_iso_text" "$iso_nspawn_script"; then
    fail "build-iso-nspawn.sh is missing: $required_nspawn_iso_text"
  fi
done

acceptance_unit="$profile_dir/airootfs/etc/systemd/system/devario-acceptance-self-check.service"
acceptance_check="$profile_dir/airootfs/usr/lib/devario/acceptance-self-check"
if ! grep -Fqx 'Requires=shelly-keyring-init.service' "$acceptance_unit" \
  || ! grep -Eq '^After=.*\bshelly-keyring-init\.service\b' "$acceptance_unit" \
  || ! grep -Fq '/var/lib/devario/shelly-keyring.ready' "$acceptance_check"; then
  fail 'release acceptance must require successful Shelly keyring initialization'
fi

if ! grep -Fq 'devario_verify_repository "$staged_core_repo" devario-core' "$project_dir/scripts/build-iso.sh" \
  || ! grep -Fq 'devario_gpgv_active_signature' "$project_dir/scripts/lib/repository.sh"; then
  fail "release ISO builds must reject unsigned repository metadata and packages"
fi

if ! grep -Fq 'core_keyring_source="${DEVARIO_CORE_KEYRING_DIR:-$project_dir/packages/devario-keyring}"' \
    "$project_dir/scripts/build-iso.sh" \
  || ! grep -Fq 'devario_validate_keyring_bundle "$core_keyring_source" devario-core' \
    "$project_dir/scripts/build-iso.sh"; then
  fail "release ISO builds must verify signatures against the fixed core keyring bundle"
fi

for required_kernel_preflight_text in \
  'linux-cachyos-lts' \
  'linux-cachyos-lts-headers' \
  'Missing required package artifacts:' \
  'build-packages-nspawn.sh linux-cachyos-lts' \
  'run-iso-builder.py'; do
  if ! grep -Fq "$required_kernel_preflight_text" \
    "$project_dir/scripts/build-iso.sh"; then
    fail "build-iso.sh does not reject an incomplete kernel repository: $required_kernel_preflight_text"
  fi
done

if ! grep -Fq 'keyring_packages=' "$project_dir/scripts/build-iso.sh" \
  || ! grep -Fq \
    'devario_verify_keyring_package "${keyring_packages[0]}" "$core_keyring_source" devario-core' \
    "$project_dir/scripts/build-iso.sh" \
  || ! grep -Fq 'devario_verify_keyring_package()' \
    "$project_dir/scripts/lib/repository.sh"; then
  fail "release ISO builds must verify the trust root inside devario-keyring"
fi

if ! python3 "$project_dir/tests/test-iso-independence.py"; then
  fail "ISO independence contract tests failed"
fi
if ! python3 "$script_dir/run-iso-builder.py" --check; then
  fail "the pinned Devario ISO builder failed verification"
fi
if grep -Eq 'mkarchiso|tools/devario-archiso' "$project_dir/scripts/build-iso.sh"; then
  fail "the ISO build must not depend on Archiso"
fi

if ! grep -Fq '/.devario-signing/' "$project_dir/.gitignore"; then
  fail ".gitignore must exclude the local repository signing-key home"
fi

if command -v gpg >/dev/null 2>&1; then
  key_file="$project_dir/packages/devario-keyring/devario.gpg"
  trusted_file="$project_dir/packages/devario-keyring/devario-trusted"
  if ! exported_fingerprint="$(
    gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null \
      | awk -F: '$1 == "fpr" { print $10; exit }'
  )"; then
    exported_fingerprint=""
  fi
  trusted_fingerprint="$(awk -F: 'NF { print $1; exit }' "$trusted_file")"
  if [[ -z "$exported_fingerprint" \
    || "$exported_fingerprint" != "$trusted_fingerprint" ]]; then
    fail "devario-trusted does not match the exported Devario public key"
  fi
  if gpg --batch --list-packets "$key_file" 2>/dev/null \
    | grep -Fq ':secret key packet:'; then
    fail "devario.gpg must never contain private signing-key material"
  fi
else
  note "gpg is unavailable; Devario public-key consistency validation was skipped."
fi

if grep -R -n -E --exclude-dir=src --exclude-dir=pkg \
  --exclude='*.pkg.tar.*' --exclude='*.log' \
  'cachyos-calamares|branding:[[:space:]]*cachyos|componentName:[[:space:]]+cachyos' \
  "$profile_dir" "$project_dir/packages"; then
  fail "found an unintended CachyOS Calamares dependency"
fi

branding_desc="$profile_dir/airootfs/usr/share/calamares/branding/devario/branding.desc"
for branding_map in strings images style uploadServer; do
  if ! grep -Eq "^${branding_map}:[[:space:]]*(\\{[[:space:]]*\\})?[[:space:]]*$" \
    "$branding_desc"; then
    fail "Calamares branding requires '$branding_map' to be a YAML map"
  fi
done
if ! grep -Eq "^[[:space:]]+type:[[:space:]]*['\\\"]?none['\\\"]?[[:space:]]*$" \
  "$branding_desc"; then
  fail "Calamares branding must explicitly disable the upload server"
fi

python_command=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then
    python_command="$candidate"
    break
  fi
done

if [[ -n "$python_command" ]] \
  && ! "$python_command" -c \
    'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' \
    "$profile_dir/late-airootfs/usr/share/devario/fastfetch/config.jsonc"; then
  fail "invalid Fastfetch JSON configuration"
fi

if [[ -n "$python_command" ]] \
  && "$python_command" -c 'import yaml' >/dev/null 2>&1; then
  while IFS= read -r yaml_file; do
    if ! "$python_command" -c \
      'import sys, yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' \
      "$yaml_file"; then
      fail "invalid YAML: ${yaml_file#"$project_dir/"}"
    fi
  done < <(
    find "$profile_dir/airootfs/etc/calamares" \
      "$profile_dir/airootfs/usr/share/calamares/branding" \
      -type f \( -name '*.conf' -o -name '*.desc' \) -print
    find "$project_dir/.github" -type f \( -name '*.yml' -o -name '*.yaml' \) -print
  )
  if ! "$python_command" -c \
    'import sys, yaml; d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")); assert all(isinstance(d.get(k), dict) for k in ("strings", "images", "style", "uploadServer")); assert d["uploadServer"].get("type") == "none"' \
    "$branding_desc"; then
    fail "Calamares branding maps do not match the required schema"
  fi
else
  note "PyYAML is unavailable; skipping YAML parse validation."
fi

keyring_unit="$profile_dir/airootfs/etc/systemd/system/shelly-keyring-init.service"
default_target="$profile_dir/airootfs/etc/systemd/system/default.target"
prepare_target="$profile_dir/airootfs/etc/calamares/modules/prepare_target.conf"
services_systemd="$profile_dir/airootfs/etc/calamares/modules/services-systemd.conf"
calamares_settings="$profile_dir/airootfs/etc/calamares/settings.conf"
unpackfs_config="$profile_dir/airootfs/etc/calamares/modules/unpackfs.conf"
partition_config="$profile_dir/airootfs/etc/calamares/modules/partition.conf"
limine_config="$profile_dir/airootfs/etc/calamares/modules/limine.conf"
limine_update="$project_dir/packages/devario-boot/limine-update"
limine_hook="$project_dir/packages/devario-boot/95-devario-boot.hook"
live_greetd_config="$profile_dir/airootfs/etc/greetd/config.toml"
installed_greetd_config="$project_dir/packages/devario-aqueous-desktop/greetd-config.toml"
live_session_wrapper="$profile_dir/airootfs/usr/local/bin/devario-aqueous-live-session"
live_installer_desktop="$profile_dir/airootfs/usr/share/applications/install-devario.desktop"
live_installer_polkit="$profile_dir/airootfs/etc/polkit-1/rules.d/49-devario-live-installer.rules"
live_bashrc="$profile_dir/late-airootfs/etc/skel/.bashrc"
fastfetch_config="$profile_dir/late-airootfs/usr/share/devario/fastfetch/config.jsonc"
live_sysusers="$profile_dir/late-airootfs/usr/lib/sysusers.d/devario-live.conf"
live_tmpfiles="$profile_dir/late-airootfs/usr/lib/tmpfiles.d/devario-live.conf"

if [[ -e "$profile_dir/airootfs/usr/lib/sysusers.d/devario-live.conf" \
  || -e "$profile_dir/airootfs/usr/lib/tmpfiles.d/devario-live.conf" ]]; then
  fail "live-user declarations must not be visible to package installation hooks"
fi
if ! grep -Fqx \
  'u liveuser 1000 "Devario Live User" /home/liveuser /usr/bin/bash' \
  "$live_sysusers" \
  || ! grep -Fqx 'C /home/liveuser 0755 liveuser liveuser - /etc/skel' \
    "$live_tmpfiles"; then
  fail "the late airootfs overlay does not define the Devario live account"
fi
if grep -Eq '^liveuser:' "$profile_dir/airootfs/etc/passwd"; then
  fail "the Devario ISO profile materializes liveuser in /etc/passwd"
fi
for required_fastfetch_bashrc_text in \
  '[[ $- != *i* ]] && return' \
  '-z ${DEVARIO_FASTFETCH_SHOWN:-}' \
  'export DEVARIO_FASTFETCH_SHOWN=1' \
  'command -v fastfetch >/dev/null 2>&1' \
  'fastfetch \' \
  '-l /usr/share/devario/fastfetch/devario-fish.txt' \
  '--config /usr/share/devario/fastfetch/config.jsonc'; do
  if ! grep -Fq -- "$required_fastfetch_bashrc_text" "$live_bashrc"; then
    fail "the default interactive shell does not launch Fastfetch safely: $required_fastfetch_bashrc_text"
  fi
done
if grep -Fq -- '--packages-format' "$live_bashrc"; then
  fail "the default interactive shell uses Fastfetch's removed module-option CLI"
fi
for required_fastfetch_config_text in \
  '"type": "packages"' \
  '"format": "{pacman} (Shelly)"'; do
  if ! grep -Fq "$required_fastfetch_config_text" "$fastfetch_config"; then
    fail "the Fastfetch JSON configuration is missing: $required_fastfetch_config_text"
  fi
done

if [[ -e "$profile_dir/airootfs/etc/calamares/modules/bootloader.conf" \
  || -e "$profile_dir/airootfs/etc/calamares/modules/grubcfg.conf" ]]; then
  fail "the installed-system GRUB modules must not be present"
fi
if grep -Eq '^[[:space:]]*-[[:space:]]*(grubcfg|bootloader)[[:space:]]*$' \
  "$calamares_settings"; then
  fail "Calamares still schedules a GRUB bootloader module"
fi
if ! grep -Fq 'module: shellprocess' "$calamares_settings" \
  || ! grep -Fq 'config: limine.conf' "$calamares_settings" \
  || ! grep -Fq 'shellprocess@limine' "$calamares_settings"; then
  fail "Calamares does not schedule the dedicated Limine installation job"
fi
if ! grep -Fqx '  - source: "/run/devario/install-root"' "$unpackfs_config" \
  || ! grep -Fqx '    sourcefs: "file"' "$unpackfs_config"; then
  fail "Calamares must install from the pristine Devario live root"
fi
if grep -Fq '/run/iso/bootmnt' "$unpackfs_config"; then
  fail "Calamares unpackfs must not depend on bootmnt, which copy-to-RAM unmounts"
fi
prepare_target_kernel="$profile_dir/airootfs/usr/lib/devario/prepare-target-kernel"
for required_kernel_install_text in \
  '/usr/lib/devario/prepare-target-kernel' \
  'rm -f /usr/lib/devario/prepare-target-kernel' \
  'test -s /boot/vmlinuz-linux-cachyos-lts'; do
  if ! grep -Fq "$required_kernel_install_text" "$prepare_target"; then
    fail "Calamares target preparation is missing: $required_kernel_install_text"
  fi
done
if grep -Fq '$' "$prepare_target"; then
  fail "Calamares target-preparation commands must not contain shell variables that its macro expander consumes"
fi
if ! grep -Fq 'devario_kernel_select' "$prepare_target_kernel"; then
  fail "Calamares must use Devario kernel metadata selection"
fi
if grep -Eq '^[[:space:]]*-[[:space:]]*(initcpio|initcpiocfg)[[:space:]]*$' "$calamares_settings"; then
  fail "Calamares still invokes mkinitcpio"
fi
if [[ -d "$profile_dir/airootfs/etc/mkinitcpio.d" ]] \
  && [[ -n "$(find "$profile_dir/airootfs/etc/mkinitcpio.d" -type f -print -quit)" ]]; then
  fail "obsolete mkinitcpio presets remain in the profile"
fi
for live_boot_config in \
  "$profile_dir/efiboot/loader/entries/01-devario-linux.conf" \
  "$profile_dir/grub/grub.cfg" \
  "$profile_dir/grub/loopback.cfg" \
  "$profile_dir/syslinux/devario_sys-linux.cfg" \
  "$profile_dir/syslinux/devario_pxe-linux.cfg"; do
  if ! grep -Fq 'vmlinuz-linux-cachyos-lts' "$live_boot_config" \
    || ! grep -Fq 'initramfs-linux-cachyos-lts.img' "$live_boot_config" \
    || ! grep -Fq 'root=live:' "$live_boot_config" \
    || ! grep -Fq 'rd.overlay=1' "$live_boot_config"; then
    fail "${live_boot_config#"$project_dir/"} does not boot the CachyOS LTS live kernel"
  fi
done
if ! grep -Fqx 'efiSystemPartition: "/boot"' "$partition_config" \
  || ! grep -Fqx 'efiSystemPartitionSize: 4096M' "$partition_config" \
  || ! grep -Fqx 'createHybridBootloaderLayout: true' "$partition_config" \
  || ! grep -Fqx 'defaultFileSystemType: "btrfs"' "$partition_config"; then
  fail "Calamares must use Btrfs with the 4096M FAT /boot and hybrid Limine layout"
fi
if ! grep -Fqx '  - "/usr/lib/devario/boot-update --install"' "$limine_config"; then
  fail "the Limine Calamares job does not invoke the target installer"
fi
if [[ ! -x "$limine_update" ]]; then
  fail "the installed Limine update helper must be executable"
fi
for limine_helper_text in \
  'path: boot():/vmlinuz-linux-cachyos-lts' \
  'module_path: boot():/initramfs-linux-cachyos-lts.img' \
  'module_path: boot():/initramfs-linux-cachyos-lts-fallback.img' \
  'install -Dm0644 "$limine_share/BOOTX64.EFI"' \
  'limine bios-install "$disk_device"' \
  'installed_marker=/var/lib/devario/limine-installed' \
  'target installation marker is absent; skipping live-image transaction' \
  'kernel-command-line'; do
  if ! grep -Fq "$limine_helper_text" "$limine_update"; then
    fail "the Limine update helper is missing: $limine_helper_text"
  fi
done
for limine_hook_target in devario-boot devario-dracut amd-ucode intel-ucode limine; do
  if ! grep -Fqx "Target = $limine_hook_target" "$limine_hook"; then
    fail "the Limine ALPM hook does not track $limine_hook_target"
  fi
done
if ! grep -Fqx 'Exec = /usr/lib/devario/boot-update' "$limine_hook"; then
  fail "the Limine ALPM hook does not invoke the update helper"
fi

installed_grub_references="$(
  grep -RInEi \
    '(^|[^[:alnum:]_-])(grub|grubcfg|os-prober)([^[:alnum:]_-]|$)' \
    "$profile_dir/airootfs/etc/calamares" \
    "$profile_dir/airootfs/usr/lib/devario" \
    "$profile_dir/airootfs/usr/share/libalpm" 2>/dev/null || true
)"
if [[ -n "$installed_grub_references" ]]; then
  echo "$installed_grub_references" >&2
  fail "the installed-system configuration retains a GRUB integration"
fi

if grep -Eq '^[[:space:]]*-[[:space:]]*displaymanager[[:space:]]*$' \
  "$calamares_settings"; then
  fail "Calamares must not rewrite Devario's Noctalia Greeter configuration"
fi
if [[ -e "$profile_dir/airootfs/etc/calamares/modules/displaymanager.conf" ]]; then
  fail "the obsolete Calamares display-manager configuration is still present"
fi

for greetd_config in "$live_greetd_config" "$installed_greetd_config"; do
  if ! grep -Fqx 'command = "/usr/bin/noctalia-greeter-session -- --session Aqueous"' \
    "$greetd_config" \
    || ! grep -Fqx 'user = "greeter"' "$greetd_config"; then
    fail "${greetd_config#"$project_dir/"} does not launch Noctalia Greeter with Aqueous selected"
  fi
done
if ! grep -Fqx '[initial_session]' "$live_greetd_config" \
  || ! grep -Fqx 'command = "/usr/local/bin/devario-aqueous-live-session"' \
    "$live_greetd_config" \
  || ! grep -Fqx 'user = "liveuser"' "$live_greetd_config"; then
  fail "the live greetd configuration does not autologin liveuser through Aqueous"
fi
if grep -Fqx '[initial_session]' "$installed_greetd_config"; then
  fail "the installed greetd template must not retain live autologin"
fi
if ! grep -Fq 'exec /usr/bin/uwsm start -- aqueous-wm' "$live_session_wrapper"; then
  fail "the live session wrapper does not enter Aqueous through UWSM"
fi
if ! grep -Fq \
  'install -Dm644 /usr/share/devario/greetd/config.toml /etc/greetd/config.toml' \
  "$prepare_target"; then
  fail "Calamares does not restore the installed Noctalia Greeter template"
fi
if ! grep -Fq 'rm -f /usr/local/bin/devario-aqueous-live-session' \
  "$prepare_target"; then
  fail "Calamares does not remove the live-only Aqueous autologin wrapper"
fi
for required_live_user_cleanup in \
  'rm -f /usr/lib/sysusers.d/devario-live.conf' \
  'rm -f /usr/lib/tmpfiles.d/devario-live.conf' \
  'if getent passwd liveuser >/dev/null; then userdel --remove liveuser; fi' \
  'if getent group liveuser >/dev/null; then groupdel liveuser; fi' \
  'rm -rf /home/liveuser'; do
  if ! grep -Fq "$required_live_user_cleanup" "$prepare_target"; then
    fail "Calamares live-user cleanup is missing: $required_live_user_cleanup"
  fi
done
if ! grep -Fq \
  'rm -f /etc/polkit-1/rules.d/49-devario-live-installer.rules' \
  "$prepare_target"; then
  fail "Calamares does not remove the live-only installer authorization"
fi
if ! grep -A3 -F 'name: greetd.service' "$services_systemd" \
  | grep -Fq 'action: enable'; then
  fail "Calamares must enable greetd on the installed system"
fi
if ! grep -A3 -F 'name: greetd.service' "$services_systemd" \
  | grep -Fq 'mandatory: true'; then
  fail "Calamares must treat greetd enablement as mandatory"
fi
if ! grep -Eq '^(Wants|After)=.*greetd\.service' "$default_target"; then
  fail "the live default target does not start greetd"
fi
if ! grep -Fxq 'Before=greetd.service' "$keyring_unit"; then
  fail "the keyring initialization service must finish before greetd"
fi

legacy_desktop_references="$(
  grep -RInEi --exclude='*.tar.*' --exclude='*.pkg.tar.*' \
    '(^|[^[:alnum:]_-])(lightdm|xfce4?(-goodies)?|tuigreet)([^[:alnum:]_-]|$)' \
    "$profile_dir" 2>/dev/null || true
)"
if [[ -n "$legacy_desktop_references" ]]; then
  echo "$legacy_desktop_references" >&2
  fail "the Devario ISO profile retains a legacy desktop or greeter reference"
fi
if [[ -e "$profile_dir/airootfs/etc/skel/Desktop/install-devario.desktop" ]]; then
  fail "the live installer must be discovered through Noctalia, not an XFCE desktop folder"
fi
if [[ ! -f "$live_installer_desktop" ]]; then
  fail "the Noctalia launcher is missing the Install Devario desktop entry"
fi
if ! grep -Fqx 'Exec=/usr/bin/pkexec /usr/bin/calamares' \
  "$live_installer_desktop"; then
  fail "the live installer desktop entry must launch Calamares through Polkit"
fi
for required_polkit_text in \
  'action.id == "io.calamares.calamares.pkexec.run"' \
  'subject.user == "liveuser"' \
  'return polkit.Result.YES;'; do
  if ! grep -Fq "$required_polkit_text" "$live_installer_polkit"; then
    fail "the live installer Polkit rule is missing: $required_polkit_text"
  fi
done
if grep -Eq 'subject\.(local|active)' "$live_installer_polkit"; then
  fail "the live installer Polkit rule must support UWSM-managed processes outside the logind session scope"
fi
if ! grep -Fq \
  '"/etc/polkit-1/rules.d/49-devario-live-installer.rules": "644"' \
  "$profile_dir/profile.json"; then
  fail "the live installer Polkit rule must be root-owned and world-readable"
fi

for required_line in \
  'Requires=shelly-storage-migrate.service' \
  'ExecStart=/usr/bin/shelly keyring init' \
  'ExecStart=/usr/bin/shelly keyring populate devario-core seafoam-labs' \
  'ExecStart=/usr/bin/install -Dm644 /dev/null /var/lib/devario/shelly-keyring.ready'; do
  if ! grep -Fxq "$required_line" "$keyring_unit"; then
    fail "shelly-keyring-init.service is missing: $required_line"
  fi
done

if ! grep -Eq '^(Wants|After)=.*shelly-keyring-init\.service' "$default_target"; then
  fail "the live default target does not order shelly-keyring-init.service"
fi

if grep -Fq 'rm -f /etc/systemd/system/shelly-keyring-init.service' "$prepare_target"; then
  fail "Calamares must retain the first-boot Shelly keyring service"
fi

if ! grep -A3 -F 'name: shelly-keyring-init.service' "$services_systemd" \
  | grep -Fq 'action: enable'; then
  fail "Calamares must enable the first-boot Shelly keyring service"
fi

if ! grep -Fq 'rm -f /var/lib/devario/shelly-keyring.ready' "$prepare_target"; then
  fail "Calamares must clear the live keyring marker so installed first boot runs initialization"
fi

if ! grep -A3 -F 'name: shelly-keyring-init.service' "$services_systemd" \
  | grep -Fq 'mandatory: true'; then
  fail "Calamares must treat the first-boot Shelly keyring service as mandatory"
fi

if find "$profile_dir/airootfs" -type f -o -type l \
  | grep -Eq '(^|/)pacman-init\.service$'; then
  fail "the legacy pacman-init.service is still present"
fi

# Pacman-shaped path names are ALPM compatibility interfaces. Actual runtime
# invocations are never allowed, including invocations embedded in Calamares.
runtime_pacman_calls="$(
  grep -RInE \
    "(^|[=[:space:]\"'])(sudo[[:space:]]+)?(/usr/bin/)?(pacman|pacman-key|pacman-conf|pacstrap)([[:space:]\"']|$)" \
    "$profile_dir/airootfs" "$profile_dir/late-airootfs" 2>/dev/null || true
)"
if [[ -n "$runtime_pacman_calls" ]]; then
  echo "$runtime_pacman_calls" >&2
  fail "found a Pacman executable call in the live or installed filesystem"
fi

# Scan active build entry points separately from removal patches and upstream
# source archives. Compatibility paths used only by migration do not match an
# executable token, while quoted and unquoted process targets do.
build_process_calls="$(
  find "$project_dir/scripts" -maxdepth 1 -type f -name '*.sh' ! -name validate.sh \
    -exec grep -HnE \
      "(^|[=[:space:]\"'])(sudo[[:space:]]+)?(/usr/bin/)?(pacman|pacman-key|pacman-conf|pacstrap)([[:space:]\"']|$)" \
      {} + 2>/dev/null || true
)"
if [[ -n "$build_process_calls" ]]; then
  echo "$build_process_calls" >&2
  fail "found a forbidden package-manager process in an active build script"
fi

package_function_calls="$(
  for package_recipe in "$project_dir"/packages/*/PKGBUILD; do
    sed -n \
      '/^[[:space:]]*\(prepare\|build\|check\|package\)()[[:space:]]*{/,/^[[:space:]]*}/p' \
      "$package_recipe"
  done | grep -nE \
    "(^|[=[:space:]\"'])(sudo[[:space:]]+)?(/usr/bin/)?(pacman|pacman-key|pacman-conf|pacstrap)([[:space:]\"']|$)" \
    2>/dev/null || true
)"
if [[ -n "$package_function_calls" ]]; then
  echo "$package_function_calls" >&2
  fail "found a forbidden package-manager process in a PKGBUILD function"
fi

# Every remaining Pacman identifier must fit one of these explicit boundaries:
# documentation; the image build configuration; ALPM compatibility paths; the
# package that builds libalpm from upstream source; or build-ISO plumbing.
pacman_reference_is_allowed() {
  local relative_path="$1"
  local text="$2"

  case "$relative_path" in
    README.md|packages/*/README.md)
      return 0
      ;;
    iso/shelly.build.conf|iso/shelly.runtime.conf|iso/airootfs/etc/shelly.conf)
      return 0
      ;;
    iso/airootfs/etc/shelly.d/*)
      return 0
      ;;
    iso/airootfs/usr/lib/devario/acceptance-self-check)
      return 0
      ;;
    iso/late-airootfs/usr/share/devario/fastfetch/config.jsonc)
      [[ "$text" == *'"format": "{pacman} (Shelly)"'* ]]
      return
      ;;
    packages/devario-alpm-runtime/*)
      return 0
      ;;
    packages/devario-keyring/*|packages/seafoam-keyring/*|packages/shelly-arch-compat/*)
      return 0
      ;;
    packages/devario-base/PKGBUILD)
      [[ "$text" == *"pacman edge"* ]]
      return
      ;;
    packages/shelly/PKGBUILD)
      [[ "$text" == *0001-remove-pacman-runtime-processes.patch* ]]
      return
      ;;
    packages/shelly/.SRCINFO)
      [[ "$text" == $'\tsource = 0001-remove-pacman-runtime-processes.patch' ]]
      return
      ;;
    packages/shelly/0001-remove-pacman-runtime-processes.patch)
      # A removal patch necessarily contains the deleted upstream calls.
      return 0
      ;;
    packages/shelly/0002-support-alternate-alpm-config.patch)
      [[ "$text" == *pacman.conf* ]]
      return
      ;;
    packages/shelly/0003-use-shelly-runtime-paths.patch)
      # A replacement patch necessarily contains the removed legacy paths.
      return 0
      ;;
    iso/profile.json)
      [[ "$text" == *pacman_conf* ]]
      return
      ;;
    scripts/build-iso.sh)
      [[ "$text" == *usr/share/pacman/keyrings/* \
        || "$text" == *usr/share/pacman/keyrings/archlinux.gpg* \
        || "$text" == *'--populate-from /usr/share/pacman/keyrings'* ]]
      return
      ;;
    scripts/build-packages.sh)
      [[ "$text" == *'PACMAN="$makepkg_adapter"'* ]]
      return
      ;;
    scripts/build-packages-nspawn.sh)
      [[ "$text" == *usr/share/pacman/keyrings/* || "$text" == *'/usr/share/pacman/keyrings/archlinux.gpg'* \
        || "$text" == *'var/lib/pacman'* \
        || "$text" == *'var/cache/pacman/pkg'* \
        || "$text" == *'../pacman/pkg'* \
        || "$text" == *'pacman.d/gnupg'* \
        || "$text" == *'pacman.d/hooks'* \
        || "$text" == *mirrorlist* ]]
      return
      ;;
    scripts/build-external-packages-nspawn.sh|scripts/build-iso-controlled-nspawn.sh)
      [[ "$text" == *'usr/share/pacman/keyrings/'* \
        || "$text" == *'var/lib/pacman/'* ]]
      return
      ;;
    scripts/lib/repository.sh)
      [[ "$text" == *'usr/share/pacman/keyrings/'* ]]
      return
      ;;
    scripts/verify-controlled-builder.sh|scripts/verify-image-boundary.sh)
      [[ "$text" == *'usr/share/pacman/keyrings/'* \
        || "$text" == *'var/lib/pacman/'* \
        || "$text" == *'/var/lib/pacman'* \
        || "$text" == *'/var/cache/pacman/pkg'* \
        || "$text" == *'/etc/pacman.d/gnupg'* \
        || "$text" == *'/etc/pacman.d/hooks'* \
        || "$text" == *pacman.conf* \
        || "$text" == *pacman_config* \
        || "$text" == *PACMAN_CONFIG* ]]
      return
      ;;
  esac

  return 1
}

while IFS= read -r reference; do
  [[ -n "$reference" ]] || continue
  reference_path="${reference%%:*}"
  remainder="${reference#*:}"
  reference_line="${remainder%%:*}"
  reference_text="${remainder#*:}"
  if [[ "$reference_path" == "$profile_dir/"* ]]; then
    relative_path="iso/${reference_path#"$profile_dir/"}"
  else
    relative_path="${reference_path#"$project_dir/"}"
  fi

  if ! pacman_reference_is_allowed "$relative_path" "$reference_text"; then
    echo "$relative_path:$reference_line:$reference_text" >&2
    fail "Pacman identifier is outside the compatibility/build-host allowlist"
  fi
done < <(
  grep -RInEi --exclude=validate.sh --exclude-dir=src --exclude-dir=pkg \
    --exclude='*.pkg.tar.*' --exclude='*.log' \
    'pacman(-key|-conf)?|pacman\.conf|pacman\.d|/var/(lib|cache)/pacman' \
    "$project_dir/README.md" "$profile_dir" "$project_dir/packages" \
    "$project_dir/scripts" 2>/dev/null || true
)

if ! grep -Eq '^HoldPkg[[:space:]]*=.*\bshelly\b' "$profile_dir/shelly.build.conf" \
  || ! grep -Eq '^HoldPkg[[:space:]]*=.*\bdevario-alpm-runtime\b' "$profile_dir/shelly.build.conf"; then
  fail "the ALPM configuration must hold Shelly and devario-alpm-runtime"
fi

if grep -Eq '^HoldPkg[[:space:]]=.*\bpacman\b' "$profile_dir/shelly.build.conf"; then
  fail "the ALPM configuration must not hold the absent pacman package"
fi

if ! grep -Eq '^[[:space:]]*SigLevel[[:space:]]*=[[:space:]]*Never[[:space:]]*$' \
  "$profile_dir/shelly.build.conf"; then
  fail "the staged build repository must disable ALPM verification after build-iso verification"
fi

if grep -Eq '^[[:space:]]*SigLevel[[:space:]]*=.*\bTrustAll\b' \
  "$profile_dir/shelly.build.conf"; then
  fail "the build-time ALPM configuration must not use misleading TrustAll semantics"
fi

json_has_exact_entry() {
  local expected="$1"
  local entry_kind="$2"

  if [[ -n "$python_command" ]]; then
    "$python_command" -c '
import json
import sys

expected, entry_kind = sys.argv[1:]
payload = json.load(sys.stdin)
items = payload if isinstance(payload, list) else [payload]
if entry_kind == "package":
    found = any(isinstance(item, dict) and item.get("Name") == expected for item in items)
else:
    found = any(
        isinstance(item, dict) and expected in (item.get("Groups") or [])
        for item in items
    )
raise SystemExit(0 if found else 1)
' "$expected" "$entry_kind"
  elif command -v jq >/dev/null 2>&1; then
    if [[ "$entry_kind" == package ]]; then
      jq -e --arg expected "$expected" \
        'if type == "array" then any(.[]; .Name == $expected) else .Name == $expected end' \
        >/dev/null
    else
      jq -e --arg expected "$expected" \
        'if type == "array" then any(.[]; any(.Groups[]?; . == $expected)) else any(.Groups[]?; . == $expected) end' \
        >/dev/null
    fi
  else
    return 2
  fi
}

if command -v shelly >/dev/null 2>&1; then
  if [[ -z "$python_command" ]] && ! command -v jq >/dev/null 2>&1; then
    note "Shelly is installed, but no JSON parser is available; skipping exact repository validation."
  else
    missing_repository_entries=()
    while IFS= read -r package_name; do
      [[ -n "$package_name" && "$package_name" != \#* ]] || continue
      case "$package_name" in
        aqueous|aqueous-session|aqueous-noctalia|calamares|ckbcomp|shelly|\
        devario-filesystem|seafoam-keyring|shelly-arch-compat|devario-alpm-runtime|devario-aqueous-desktop|devario-base|devario-boot|devario-dracut|devario-keyring|\
        devario-managed-keyring|noctalia|noctalia-greeter)
          continue
          ;;
      esac

      package_json=""
      group_json=""
      if package_json="$(shelly search standard "$package_name" \
        --available --detail --json 2>/dev/null)" \
        && printf '%s' "$package_json" \
          | json_has_exact_entry "$package_name" package; then
        continue
      fi

      if group_json="$(shelly search standard "$package_name" \
        --available --group --json 2>/dev/null)" \
        && printf '%s' "$group_json" \
          | json_has_exact_entry "$package_name" group; then
        continue
      fi

      missing_repository_entries+=("$package_name")
    done < "$profile_dir/packages.x86_64"

    if (( ${#missing_repository_entries[@]} )); then
      fail "packages or exact groups missing from Shelly's configured repositories: ${missing_repository_entries[*]}"
    fi
  fi
else
  note "Shelly is unavailable; structural checks passed, but repository lookup was skipped."
fi

# Inspect generated artifacts when they exist. Structural validation remains
# useful before the first package build, so an empty repo is not an error here.
if command -v bsdtar >/dev/null 2>&1; then
  shopt -s nullglob
  devario_artifacts=("$project_dir"/repo/core/*.pkg.tar.zst)
  runtime_artifacts=("$project_dir"/repo/core/devario-alpm-runtime-[0-9]*.pkg.tar.zst)
  shelly_artifacts=("$project_dir"/repo/core/shelly-[0-9]*.pkg.tar.zst)
  ckbcomp_artifacts=("$project_dir"/repo/core/ckbcomp-[0-9]*.pkg.tar.zst)
  aqueous_artifacts=("$project_dir"/repo/core/aqueous-[0-9]*.pkg.tar.zst)
  aqueous_session_artifacts=("$project_dir"/repo/core/aqueous-session-*.pkg.tar.zst)
  aqueous_noctalia_artifacts=("$project_dir"/repo/core/aqueous-noctalia-*.pkg.tar.zst)
  noctalia_artifacts=("$project_dir"/repo/core/noctalia-[0-9]*.pkg.tar.zst)
  noctalia_greeter_artifacts=("$project_dir"/repo/core/noctalia-greeter-[0-9]*.pkg.tar.zst)
  desktop_meta_artifacts=("$project_dir"/repo/core/devario-aqueous-desktop-[0-9]*.pkg.tar.zst)

  stale_repository_files=("$project_dir"/repo/core/*.old "$project_dir"/repo/core/*.old.sig)
  if (( ${#stale_repository_files[@]} )); then
    fail "repository contains stale repo-add output: ${stale_repository_files[*]##*/}"
  fi

  if (( ${#devario_artifacts[@]} )); then
    for expected_artifact_package in \
      aqueous aqueous-noctalia aqueous-session calamares ckbcomp \
      devario-filesystem seafoam-keyring devario-alpm-runtime devario-aqueous-desktop devario-base devario-boot devario-dracut devario-keyring \
      linux-cachyos-lts linux-cachyos-lts-headers \
      noctalia noctalia-greeter shelly; do
      expected_artifacts=(
        "$project_dir"/repo/core/"$expected_artifact_package"-[0-9]*.pkg.tar.zst
      )
      if (( ${#expected_artifacts[@]} != 1 )); then
        fail "repository must contain exactly one $expected_artifact_package package artifact"
      fi
    done
  fi

  for artifact in "${devario_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    if grep -Eq '^usr/bin/(pacman|pacman-key|pacman-conf|pacstrap)$' \
      <<< "$artifact_contents"; then
      fail "$(basename -- "$artifact") contains a forbidden Pacman executable"
    fi
  done

  for artifact in "${aqueous_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    for required_path in \
      usr/bin/aqueous \
      usr/bin/aqueousctl \
      usr/lib/aqueous/libwlroots-0.20.so \
      usr/share/man/man1/aqueous.1.gz \
      usr/share/man/man1/aqueousctl.1.gz; do
      if ! grep -Fxq "$required_path" <<< "$artifact_contents"; then
        fail "$(basename -- "$artifact") is missing $required_path"
      fi
    done
    if command -v readelf >/dev/null 2>&1; then
      aqueous_extract_dir="$(mktemp -d /tmp/devario-aqueous-check.XXXXXX)"
      if bsdtar -xf "$artifact" -C "$aqueous_extract_dir" usr/bin/aqueous \
        && readelf -d "$aqueous_extract_dir/usr/bin/aqueous" \
          | grep -Fq 'Library runpath: [$ORIGIN/../lib/aqueous]'; then
        :
      else
        fail "$(basename -- "$artifact") does not use its private patched wlroots"
      fi
      rm -rf -- "$aqueous_extract_dir"
    fi
  done

  for artifact in "${aqueous_session_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    for required_path in \
      usr/bin/aqueous-init \
      usr/bin/aqueous-wm \
      usr/share/wayland-sessions/aqueous.desktop \
      etc/uwsm/env-aqueous \
      usr/share/xdg-desktop-portal/aqueous-portals.conf \
      usr/lib/systemd/user/aqueous-session.target; do
      if ! grep -Fxq "$required_path" <<< "$artifact_contents"; then
        fail "$(basename -- "$artifact") is missing $required_path"
      fi
    done
    packaged_session_entry="$(
      bsdtar -xOf "$artifact" usr/share/wayland-sessions/aqueous.desktop
    )"
    if ! grep -Fxq 'Name=Aqueous' <<< "$packaged_session_entry" \
      || ! grep -Fxq 'Exec=uwsm start -- aqueous-wm' <<< "$packaged_session_entry"; then
      fail "$(basename -- "$artifact") does not advertise the Aqueous UWSM session"
    fi
  done

  for artifact in "${aqueous_noctalia_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    for required_path in \
      usr/bin/aqueous-config \
      usr/lib/systemd/user/noctalia.service \
      usr/lib/systemd/user/graphical-session.target.wants/noctalia.service \
      usr/share/aqueous/noctalia/config.toml \
      usr/share/aqueous/noctalia-plugins/settings/plugin.toml; do
      if ! grep -Fxq "$required_path" <<< "$artifact_contents"; then
        fail "$(basename -- "$artifact") is missing $required_path"
      fi
    done
  done

  for artifact in "${noctalia_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    if ! grep -Fxq 'usr/bin/noctalia' <<< "$artifact_contents" \
      || ! grep -Eq '^usr/share/noctalia/assets/' <<< "$artifact_contents"; then
      fail "$(basename -- "$artifact") lacks the Noctalia binary or required assets"
    fi
  done

  for artifact in "${noctalia_greeter_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    greeter_pkginfo="$(bsdtar -xOf "$artifact" .PKGINFO)"
    for required_path in \
      usr/bin/noctalia-greeter \
      usr/bin/noctalia-greeter-compositor \
      usr/bin/noctalia-greeter-session \
      usr/bin/noctalia-greeter-apply-appearance \
      usr/lib/tmpfiles.d/noctalia-greeter.conf; do
      if ! grep -Fxq "$required_path" <<< "$artifact_contents"; then
        fail "$(basename -- "$artifact") is missing $required_path"
      fi
    done
    if ! grep -Eq '^usr/share/noctalia-greeter/assets/' <<< "$artifact_contents"; then
      fail "$(basename -- "$artifact") lacks the required greeter assets"
    fi
    if ! grep -Fxq 'provides = greetd-greeter' <<< "$greeter_pkginfo"; then
      fail "$(basename -- "$artifact") does not provide a greetd greeter"
    fi
    if grep -Fxq 'conflict = greetd-agreety' <<< "$greeter_pkginfo"; then
      fail "$(basename -- "$artifact") conflicts with greetd's required fallback greeter"
    fi
  done

  for artifact in "${desktop_meta_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    desktop_meta_pkginfo="$(bsdtar -xOf "$artifact" .PKGINFO)"
    for required_path in \
      usr/lib/devario/gpu-driver-setup \
      usr/lib/systemd/system/devario-gpu-driver.service \
      usr/lib/systemd/system/greetd.service.d/20-devario-gpu-driver.conf \
      usr/share/devario/greetd/config.toml; do
      if ! grep -Fxq "$required_path" <<< "$artifact_contents"; then
        fail "$(basename -- "$artifact") is missing $required_path"
      fi
    done
    for required_nvidia_dependency in \
      linux-cachyos-lts-headers nvidia-open-dkms nvidia-utils; do
      if ! grep -Eq \
        "^depend = ${required_nvidia_dependency}([<>=].*)?$" \
        <<< "$desktop_meta_pkginfo"; then
        fail "$(basename -- "$artifact") does not depend on $required_nvidia_dependency"
      fi
    done
    if grep -Eq '^depend = vulkan-nouveau([<>=].*)?$' \
      <<< "$desktop_meta_pkginfo"; then
      fail "$(basename -- "$artifact") still depends on vulkan-nouveau"
    fi
    if grep -Fxq 'etc/greetd/config.toml' <<< "$artifact_contents"; then
      fail "$(basename -- "$artifact") conflicts with greetd's owned configuration"
    fi
    packaged_greetd_config="$(
      bsdtar -xOf "$artifact" usr/share/devario/greetd/config.toml
    )"
    if ! grep -Fqx \
      'command = "/usr/bin/noctalia-greeter-session -- --session Aqueous"' \
      <<< "$packaged_greetd_config"; then
      fail "$(basename -- "$artifact") does not select Aqueous in Noctalia Greeter"
    fi
  done

  if (( ${#devario_artifacts[@]} )) \
    && command -v gpgv >/dev/null 2>&1 \
    && [[ -s "$project_dir/packages/devario-keyring/devario.gpg" ]]; then
    for signed_artifact in "${devario_artifacts[@]}"; do
      if [[ ! -s "$signed_artifact.sig" ]] \
        || ! gpgv --keyring "$project_dir/packages/devario-keyring/devario.gpg" \
          "$signed_artifact.sig" "$signed_artifact" >/dev/null 2>&1; then
        fail "$(basename -- "$signed_artifact") lacks a valid Devario signature"
      fi
    done
    for repository_database in devario-core.db.tar.zst devario-core.files.tar.zst; do
      database_path="$project_dir/repo/core/$repository_database"
      if [[ ! -s "$database_path" || ! -s "$database_path.sig" ]] \
        || ! gpgv --keyring "$project_dir/packages/devario-keyring/devario.gpg" \
          "$database_path.sig" "$database_path" >/dev/null 2>&1; then
        fail "$repository_database lacks a valid Devario signature"
      fi
    done
  fi

  for artifact in "${ckbcomp_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    ckbcomp_pkginfo="$(bsdtar -xOf "$artifact" .PKGINFO)"
    if ! grep -Eq '^usr/bin/ckbcomp$' <<< "$artifact_contents"; then
      fail "$(basename -- "$artifact") does not contain /usr/bin/ckbcomp"
    fi
    for ckbcomp_dependency in perl xkeyboard-config; do
      if ! grep -Fxq "depend = $ckbcomp_dependency" <<< "$ckbcomp_pkginfo"; then
        fail "$(basename -- "$artifact") does not require $ckbcomp_dependency"
      fi
    done
    ckbcomp_extract_dir="$(mktemp -d /tmp/devario-ckbcomp-check.XXXXXX)"
    if ! bsdtar -xf "$artifact" -C "$ckbcomp_extract_dir" usr/bin/ckbcomp; then
      fail "could not extract ckbcomp for runtime validation"
      rm -rf -- "$ckbcomp_extract_dir"
      continue
    fi
    if [[ ! -x "$ckbcomp_extract_dir/usr/bin/ckbcomp" ]]; then
      fail "$(basename -- "$artifact") does not install an executable ckbcomp"
    elif [[ -d /usr/share/X11/xkb ]]; then
      if ! "$ckbcomp_extract_dir/usr/bin/ckbcomp" \
        -model pc105 -layout us >/dev/null; then
        fail "$(basename -- "$artifact") cannot compile the US XKB layout"
      fi
    else
      note "XKB data is unavailable; ckbcomp's functional artifact check was skipped."
    fi
    rm -rf -- "$ckbcomp_extract_dir"
  done

  for artifact in "${runtime_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    runtime_pkginfo="$(bsdtar -xOf "$artifact" .PKGINFO)"
    if grep -Eq '^usr/bin/(makepkg|repo-add|repo-remove|pacman-conf|vercmp)$' \
      <<< "$artifact_contents"; then
      fail "$(basename -- "$artifact") contains a build-host-only package tool"
    fi
    if ! grep -Eq '^usr/lib/libalpm\.so\.16$' <<< "$artifact_contents"; then
      fail "$(basename -- "$artifact") does not contain the libalpm.so.16 ABI"
    fi
    if ! grep -Fxq 'provides = libalpm.so=16-64' <<< "$runtime_pkginfo"; then
      fail "$(basename -- "$artifact") does not provide the versioned libalpm.so.16 ABI"
    fi
    if ! grep -Eq '^provides = pacman=[^[:space:]]+$' <<< "$runtime_pkginfo"; then
      fail "$(basename -- "$artifact") lacks the versioned Pacman compatibility provider"
    fi
    for required_runtime_path in \
      etc/shelly.conf \
      usr/lib/devario/shelly-storage-migrate \
      usr/lib/systemd/system/shelly-storage-migrate.service \
      var/lib/shelly/ \
      var/cache/shelly/pkg/ \
      etc/shelly.d/gnupg/ \
      etc/shelly.d/hooks/; do
      if ! grep -Fxq "$required_runtime_path" <<< "$artifact_contents"; then
        fail "$(basename -- "$artifact") lacks $required_runtime_path"
      fi
    done
    if grep -Eq '^(etc/pacman\.conf|etc/pacman\.d/(gnupg|hooks)/|var/lib/pacman/|var/cache/pacman/pkg/)$' \
      <<< "$artifact_contents"; then
      fail "$(basename -- "$artifact") contains a legacy mutable runtime path"
    fi
  done

  for artifact in "${shelly_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    shelly_pkginfo="$(bsdtar -xOf "$artifact" .PKGINFO)"
    shelly_buildinfo="$(bsdtar -xOf "$artifact" .BUILDINFO)"
    if ! grep -Eq '^usr/bin/shelly$' <<< "$artifact_contents"; then
      fail "$(basename -- "$artifact") does not contain /usr/bin/shelly"
    fi
    if ! grep -Eq '^usr/bin/shelly-key$' <<< "$artifact_contents"; then
      fail "$(basename -- "$artifact") does not contain Shelly's native keyring helper"
    fi
    if ! grep -Eq '^pkgver = 3\.1\.6-' <<< "$shelly_pkginfo"; then
      fail "$(basename -- "$artifact") is not Shelly 3.1.6"
    fi
    if ! grep -Fxq 'depend = libalpm.so=16-64' <<< "$shelly_pkginfo"; then
      fail "$(basename -- "$artifact") does not require the libalpm.so.16 ABI"
    fi
    if ! grep -Fxq 'depend = devario-alpm-runtime>=7.1.0.r9.g54d9411-2' <<< "$shelly_pkginfo"; then
      fail "$(basename -- "$artifact") does not require the Shelly-path runtime migration"
    fi
    if ! grep -Fxq 'etc/shellybuild.conf' <<< "$artifact_contents" \
      || ! grep -Fxq 'backup = etc/shellybuild.conf' <<< "$shelly_pkginfo"; then
      fail "$(basename -- "$artifact") does not package Shelly's native-builder policy"
    fi
    if ! grep -Fxq 'options = !autodeps' <<< "$shelly_buildinfo" \
      || ! grep -Eq '^installed = .+-.+-.+$' \
        <<< "$shelly_buildinfo"; then
      fail "$(basename -- "$artifact") was not built with the strict Shelly inventory path"
    fi
    if command -v readelf >/dev/null 2>&1; then
      artifact_extract_dir="$(mktemp -d /tmp/devario-shelly-check.XXXXXX)"
      if ! bsdtar -xf "$artifact" -C "$artifact_extract_dir" usr/bin/shelly; then
        fail "could not extract Shelly for ELF validation"
        rm -rf -- "$artifact_extract_dir"
        continue
      fi
      if ! dynamic_entries="$(readelf -d "$artifact_extract_dir/usr/bin/shelly")"; then
        fail "could not inspect Shelly's ELF dependencies"
        rm -rf -- "$artifact_extract_dir"
        continue
      fi
      if ! grep -Fq 'Shared library: [libalpm.so.16]' <<< "$dynamic_entries"; then
        fail "$(basename -- "$artifact") does not link Shelly to libalpm.so.16"
      fi
      if command -v strings >/dev/null 2>&1; then
        shelly_strings="$(strings "$artifact_extract_dir/usr/bin/shelly" 2>/dev/null || true)"
        if grep -Fxq 'pacman' <<< "$shelly_strings" \
          || grep -Fq 'pacman-key' <<< "$shelly_strings" \
          || grep -Fq 'pacstrap' <<< "$shelly_strings" \
          || grep -Fxq -- '-Qoq' <<< "$shelly_strings"; then
          fail "$(basename -- "$artifact") retains a Pacman executable invocation"
        fi
        if ! grep -Fq '/usr/bin/shelly-key' <<< "$shelly_strings" \
          || ! grep -Fq '/usr/bin/gpg' <<< "$shelly_strings" \
          || ! grep -Fq 'SHELLY_ALPM_CONFIG' <<< "$shelly_strings" \
          || ! grep -Fq '/etc/shelly.conf' <<< "$shelly_strings" \
          || ! grep -Fq '/var/lib/shelly' <<< "$shelly_strings" \
          || ! grep -Fq '/var/cache/shelly/pkg' <<< "$shelly_strings" \
          || ! grep -Fq '/etc/shelly.d/gnupg' <<< "$shelly_strings" \
          || ! grep -Fq 'Isolated root provisioning is unavailable on Devario' \
            <<< "$shelly_strings"; then
          fail "$(basename -- "$artifact") does not use the patched native keyring helpers"
        fi
        if grep -Fq '/etc/pacman.conf' <<< "$shelly_strings" \
          || grep -Fq '/var/lib/pacman' <<< "$shelly_strings" \
          || grep -Fq '/var/cache/pacman/pkg' <<< "$shelly_strings" \
          || grep -Fq '/etc/pacman.d/gnupg' <<< "$shelly_strings"; then
          fail "$(basename -- "$artifact") retains a legacy runtime path"
        fi
      else
        note "strings is unavailable; Shelly's process-target check was skipped."
      fi
      rm -rf -- "$artifact_extract_dir"
    else
      note "readelf is unavailable; Shelly's libalpm DT_NEEDED check was skipped."
    fi
  done

else
  note "bsdtar is unavailable; built-package content validation was skipped."
fi

if (( failed )); then
  exit 1
fi

echo "Devario $DEVARIO_EDITION_VARIANT edition and Shelly-first profile validation passed."
