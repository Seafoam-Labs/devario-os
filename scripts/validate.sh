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

# shellcheck source=lib/python-env.sh
source "$script_dir/lib/python-env.sh"
devario_use_validation_python

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
  "$project_dir/scripts/stage-image-links.sh"
  "$project_dir/scripts/stage-iso-repositories.py"
  "$profile_dir/profile.json"
  "$profile_dir/packages.x86_64"
  "$profile_dir/shelly.build.conf"
  "$profile_dir/shelly.runtime.conf"
  "$profile_dir/airootfs/etc/calamares/settings.conf"
  "$profile_dir/airootfs/etc/calamares/modules/unpackfs.conf"
  "$profile_dir/airootfs/etc/calamares/modules/partition.conf"
  "$profile_dir/airootfs/etc/calamares/modules/users.conf"
  "$profile_dir/airootfs/etc/calamares/modules/systemd_boot.conf"
  "$profile_dir/airootfs/etc/calamares/modules/boot_preflight.conf"
  "$profile_dir/airootfs/etc/calamares/modules/prepare_target.conf"
  "$profile_dir/airootfs/etc/calamares/modules/nvidia_preflight.conf"
  "$profile_dir/airootfs/etc/calamares/modules/nvidia.conf"
  "$profile_dir/airootfs/etc/calamares/modules/update_preflight.conf"
  "$profile_dir/airootfs/etc/calamares/modules/update_target.conf"
  "$profile_dir/airootfs/usr/lib/devario/update-target-packages"
  "$project_dir/tests/test-update-target-packages.py"
  "$profile_dir/airootfs/etc/calamares/modules/keyboard_aqueous.conf"
  "$profile_dir/airootfs/usr/lib/devario/configure-target-keyboard"
  "$project_dir/tests/test-configure-target-keyboard.py"
  "$profile_dir/airootfs/usr/lib/devario/configure-target-nvidia"
  "$profile_dir/airootfs/usr/share/devario/nvidia-supported-gpus.json"
  "$project_dir/tests/test-configure-target-nvidia.py"
  "$project_dir/tests/test-nvidia-preflight-image.py"
  "$project_dir/tests/test-pearl-desktop.py"
  "$project_dir/tests/test-qemu-graphics.py"
  "$project_dir/scripts/lib/qemu-graphics.sh"
  "$project_dir/scripts/test-live-desktop.py"
  "$profile_dir/airootfs/usr/lib/devario/desktop-self-check"
  "$profile_dir/airootfs/usr/lib/devario/graphics-session"
  "$profile_dir/airootfs/etc/xdg/uwsm/env.d/61-devario-virtio.sh"
  "$profile_dir/late-airootfs/usr/share/devario/greetd/config.toml"
  "$profile_dir/airootfs/etc/systemd/system/devario-desktop-self-check.service"
  "$project_dir/tests/test-live-installer.js"
  "$project_dir/tests/test-start-installer.py"
  "$profile_dir/airootfs/usr/lib/devario/start-installer"
  "$profile_dir/airootfs/usr/lib/devario/prepare-live-desktop"
  "$profile_dir/airootfs/etc/xdg/uwsm/env.d/55-devario-user-dirs.sh"
  "$profile_dir/late-airootfs/etc/skel/.config/pearl/preferences.json"
  "$profile_dir/late-airootfs/usr/share/applications/calamares.desktop"
  "$profile_dir/airootfs/etc/xdg/uwsm/env.d/60-devario-gpu.sh"
  "$profile_dir/airootfs/etc/calamares/modules/services-systemd.conf"
  "$profile_dir/late-airootfs/etc/greetd/config.toml"
  "$profile_dir/airootfs/etc/polkit-1/rules.d/49-devario-live-installer.rules"
  "$profile_dir/late-airootfs/etc/systemd/system/devario-live.target"
  "$profile_dir/airootfs/etc/systemd/system/devario-acceptance-self-check.service"
  "$profile_dir/airootfs/etc/systemd/system/multi-user.target.wants/devario-acceptance-self-check.service"
  "$profile_dir/airootfs/etc/systemd/system/shelly-keyring-init.service"
  "$profile_dir/airootfs/usr/lib/devario/acceptance-self-check"
  "$project_dir/packages/devario-boot/systemd-boot-update"
  "$profile_dir/airootfs/usr/lib/devario/prepare-target-kernel"
  "$profile_dir/airootfs/usr/local/bin/devario-aqueous-live-session"
  "$project_dir/packages/devario-boot/95-devario-boot.hook"
  "$profile_dir/airootfs/usr/share/calamares/branding/devario/branding.desc"
  "$profile_dir/late-airootfs/etc/skel/.bashrc"
  "$profile_dir/late-airootfs/etc/skel/.config/fish/config.fish"
  "$profile_dir/late-airootfs/etc/skel/.config/aqueous/layout.toml"
  "$profile_dir/late-airootfs/etc/xdg/aqueous/layout.toml"
  "$profile_dir/late-airootfs/usr/share/devario/fastfetch/config.jsonc"
  "$profile_dir/late-airootfs/usr/share/devario/fastfetch/devario-fish.txt"
  "$profile_dir/late-airootfs/usr/share/devario/fastfetch/devario-logo.png"
  "$profile_dir/late-airootfs/etc/xdg/fastfetch/config.jsonc"
  "$profile_dir/late-airootfs/usr/lib/sysusers.d/devario-live.conf"
  "$profile_dir/late-airootfs/usr/lib/tmpfiles.d/devario-live.conf"
  "$project_dir/packages/calamares/PKGBUILD"
  "$project_dir/packages/calamares/verify-isa.py"
  "$script_dir/verify-calamares-isa.sh"
  "$project_dir/tests/test-calamares-isa.py"
  "$project_dir/packages/calamares/0001-devario-wayland-runtime.patch"
  "$project_dir/packages/calamares/0003-devario-update-warning.patch"
  "$project_dir/tests/test-calamares-update-warning.py"
  "$project_dir/packages/ckbcomp/PKGBUILD"
  "$project_dir/packages/devario-base/PKGBUILD"
  "$project_dir/packages/devario-filesystem/profile"
  "$project_dir/tests/test-filesystem-profile.py"
  "$project_dir/packages/devario-base/shelly.conf"
  "$project_dir/packages/devario-base/shelly-storage-migrate"
  "$project_dir/packages/devario-base/shelly-storage-migrate.service"
  "$project_dir/packages/devario-base/devario-base.install"
  "$project_dir/packages/devario-base/devario-report.sh"
  "$project_dir/packages/devario-base/devario-report.desktop"
  "$project_dir/tests/test-devario-report.py"
  "$project_dir/packages/devario-boot/PKGBUILD"
  "$project_dir/packages/devario-boot/initramfs-update"
  "$project_dir/packages/devario-boot/boot-update"
  "$project_dir/tests/test-dracut-boot.sh"
  "$project_dir/tests/test-dracut-live-qemu.sh"
  "$project_dir/packages/devario-aqueous-desktop/PKGBUILD"
  "$project_dir/packages/devario-aqueous-desktop/session.toml"
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
  "$project_dir/scripts/validate-kernel-package.sh"
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
  printf '%s\n' "$project_dir/packages/devario-filesystem/profile"
  printf '%s\n' "$profile_dir/airootfs/etc/xdg/uwsm/env.d/60-devario-gpu.sh"
  for boot_helper in kernel.sh kernel-command-line initramfs-update boot-update systemd-boot-update kernel-reboot-notify module-setup.sh live-root.sh install-root.sh verify-live-image; do
    printf '%s\n' "$project_dir/packages/devario-boot/$boot_helper"
  done
  printf '%s\n' "$profile_dir/airootfs/usr/lib/devario/prepare-target-kernel"
  printf '%s\n' "$profile_dir/airootfs/usr/lib/devario/acceptance-self-check"
  printf '%s\n' "$project_dir/packages/devario-aqueous-desktop/gpu-driver-setup"
  printf '%s\n' "$project_dir/tests/fixtures/gpu-driver-setup/mock-modprobe"
  printf '%s\n' "$project_dir/tests/test-gpu-driver-setup.sh"
  printf '%s\n' "$project_dir/tests/test-prepare-target-kernel.sh"
  printf '%s\n' "$project_dir/packages/devario-base/shelly-storage-migrate"
  printf '%s\n' "$project_dir/packages/devario-base/devario-base.install"
  printf '%s\n' "$project_dir/packages/devario-base/devario-report.sh"
)

while IFS= read -r python_file; do
  if ! python3 -c 'import pathlib,sys; source=pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"); compile(source,sys.argv[1],"exec")' "$python_file"; then
    fail "Python syntax check failed: ${python_file#"$project_dir/"}"
  fi
done < <(find "$project_dir/release" "$project_dir/scripts" -maxdepth 1 -type f -name '*.py' -print | sort)

if ! python3 "$project_dir/scripts/render-calamares-theme.py" --check; then
  fail "Calamares theme assets are stale"
fi
if ! python3 "$project_dir/tests/test-calamares-theme.py"; then
  fail "Calamares appearance and branding consistency tests failed"
fi
if ! python3 "$project_dir/tests/test-calamares-isa.py"; then
  fail 'Calamares x86-64-v3 artifact gate tests failed'
fi
if [[ -e "$profile_dir/airootfs/etc/calamares/branding/devario" ]]; then
  fail "Calamares branding must have a single source under /usr/share"
fi
if ! python3 "$project_dir/scripts/render-calamares-theme.py" --check \
  --output "$profile_dir/airootfs/usr/share/calamares/branding/devario"; then
  fail "Composed profile changed the generated Calamares appearance"
fi
if ! DEVARIO_VALIDATION_TEST_WHEELHOUSE="${DEVARIO_VALIDATION_WHEELHOUSE:-${VIRTUAL_ENV%/envs/*}/wheels}" \
  python3 "$project_dir/tests/test-validation-env.py"; then
  fail "Python validation environment tests failed"
fi
if ! DEVARIO_PROFILE_DIR="$profile_dir" python3 "$project_dir/tests/test-systemd-boot.py"; then
  fail "systemd-boot deployment and installer preflight tests failed"
fi
if ! python3 "$project_dir/tests/test-kernel-reboot-notify.py"; then
  fail "Kernel reboot notification tests failed"
fi
if ! python3 "$project_dir/tests/test-filesystem-profile.py"; then
  fail "Filesystem login profile tests failed"
fi
if ! python3 "$project_dir/tests/test-stage-core-repository.py"; then
  fail "Repository staging and provider selection tests failed"
fi
if ! python3 "$project_dir/tests/test-stage-iso-repositories.py"; then
  fail "Multi-repository ISO staging tests failed"
fi
if ! DEVARIO_PROFILE_DIR="$profile_dir" python3 "$project_dir/tests/test-pearl-desktop.py"; then
  fail "Pearl desktop and live login integration tests failed"
fi
if ! python3 "$project_dir/tests/test-qemu-graphics.py"; then
  fail "QEMU Venus setup behavior tests failed"
fi
if ! DEVARIO_PROFILE_DIR="$profile_dir" node "$project_dir/tests/test-live-installer.js"; then
  fail "Live installer authorization tests failed (Node.js is required)"
fi
if ! DEVARIO_PROFILE_DIR="$profile_dir" python3 "$project_dir/tests/test-start-installer.py"; then
  fail "the live installer privilege and Wayland handoff tests failed"
fi
if ! python3 "$project_dir/tests/test-devario-report.py"; then
  fail "Devario report behavior and packaging tests failed"
fi
if ! python3 "$project_dir/tests/test-egpu.py"; then
  fail "eGPU session, hot-plug and packaging tests failed"
fi
if ! bash "$project_dir/tests/test-gpu-driver-setup.sh"; then
  fail "GPU driver setup behavior tests failed"
fi
if ! DEVARIO_PROFILE_DIR="$profile_dir" \
  python3 "$project_dir/tests/test-configure-target-nvidia.py"; then
  fail "Calamares NVIDIA installation behavior tests failed"
fi
if [[ -n "${DEVARIO_NVIDIA_TEST_ROOT:-}" ]] && ! DEVARIO_PROFILE_DIR="$profile_dir" \
  python3 "$project_dir/tests/test-nvidia-preflight-image.py" "$DEVARIO_NVIDIA_TEST_ROOT"; then
  fail "Calamares NVIDIA preflight image integration tests failed"
fi
if ! DEVARIO_PROFILE_DIR="$profile_dir" python3 "$project_dir/tests/test-update-target-packages.py"; then
  fail "Calamares installation update behavior tests failed"
fi
if ! DEVARIO_PROFILE_DIR="$profile_dir" python3 "$project_dir/tests/test-configure-target-keyboard.py"; then
  fail "Calamares Aqueous keyboard installation behavior tests failed"
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
  fail 'the prepared Python environment lacks jsonschema for Draft 2020-12 release validation'
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
  aqueous-core aqueous-session aqueous-integration-pearl aqueous-shell-pearl xdg-desktop-portal-aqueous \
  calamares ckbcomp devario-desktop \
  devario-base devario-boot devario-dracut devario-keyring greetd systemd pearl pearl-greeter shelly fastfetch fish \
  chafa imagemagick ghostty gnome-keyring seahorse upower power-profiles-daemon adw-gtk3 papirus-icon-theme vimix-cursors \
  strace ripgrep vulkan-tools mesa-utils wayland-utils usbutils lsof nvme-cli netcat matugen \
  linux-devario linux-devario-headers nvidia-open-dkms nvidia-utils \
  vulkan-intel vulkan-radeon vulkan-swrast vulkan-virtio xorg-xwayland; do
  if ! package_is_listed "$required_package"; then
    fail "packages.x86_64 does not include $required_package"
  fi
done

for forbidden_package in \
  noctalia noctalia-greeter aqueous-noctalia aqueous-integration-noctalia aqueous-shell-noctalia \
  devario-alpm-runtime mkinitcpio mkinitcpio-archiso pacman base linux grub os-prober lightdm lightdm-gtk-greeter xfce4 xfce4-goodies \
  xorg-server xorg-xinit greetd-agreety greetd-tuigreet vulkan-nouveau; do
  if package_is_listed "$forbidden_package"; then
    fail "packages.x86_64 must not include $forbidden_package"
  fi
done

declare -A expected_pkgnames=(
  [calamares]=calamares
  [ckbcomp]=ckbcomp
  [devario-aqueous-desktop]=devario-aqueous-desktop
  [devario-filesystem]=devario-filesystem
  [seafoam-keyring]=seafoam-keyring
  [devario-base]=devario-base
  [devario-boot]=devario-boot
  [devario-keyring]=devario-keyring
)

for package_dir_name in "${!expected_pkgnames[@]}"; do
  expected_pkgname="${expected_pkgnames[$package_dir_name]}"
  pkgbuild="$project_dir/packages/$package_dir_name/PKGBUILD"
  if ! grep -Eq "^[[:space:]]*pkgname=['\"]?${expected_pkgname}['\"]?[[:space:]]*$" "$pkgbuild"; then
    fail "$package_dir_name/PKGBUILD does not declare pkgname=$expected_pkgname"
  fi
done

# validate-kernel-package.sh checks an explicit external recipe directory.
# OS validation checks the selected kernel, boot integration, and supplied artifacts.

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
  ["packages/devario-aqueous-desktop/graphics-session"]='79f25aad3be3af1214c3453c18dced5b8a0cc90087374752f59ba6d7d95eb02e'
  ["packages/devario-aqueous-desktop/61-devario-virtio.sh"]='4670c72c1612df9e7a0b9ccb5e61cb9d224d7e33a30b8029ad8a6853b249442e'
  ["packages/devario-aqueous-desktop/devario-gpu-driver.service"]='ec8e672fb2e7a451bd97ca9ccbc4ade0a91a7f0e097a5e3a6ce99ec144871807'
  ["packages/devario-aqueous-desktop/gpu-driver-setup"]='455389932d08ed61668fdf010debf46ff7a282e54142019a7a52c171ee672d34'
  ["packages/devario-aqueous-desktop/greetd-config.toml"]='ef1c8b33c7a25969f2268588ca6f100c4905f46b238ff2998ef26f91fdfb1386'
  ["packages/devario-aqueous-desktop/greetd-gpu-driver.conf"]='271e59b1fe07474aa8626ff739832b255827f5302fbde690d0ed8fd1a5d94bb7'
)
for pinned_path in "${!pinned_desktop_sources[@]}"; do
  actual_sha256="$(sha256sum "$project_dir/$pinned_path")"
  actual_sha256="${actual_sha256%% *}"
  if [[ "$actual_sha256" != "${pinned_desktop_sources[$pinned_path]}" ]]; then
    fail "$pinned_path failed its pinned SHA-256 checksum"
  fi
done

for desktop_recipe in devario-aqueous-desktop; do
  if grep -Eq "^[[:space:]]*['\"]?SKIP['\"]?([[:space:]]|$)" \
    "$project_dir/packages/$desktop_recipe/PKGBUILD"; then
    fail "$desktop_recipe contains an unchecked source"
  fi
done

desktop_meta="$project_dir/packages/devario-aqueous-desktop/PKGBUILD"
for desktop_dependency in \
  aqueous-core aqueous-session aqueous-integration-pearl aqueous-shell-pearl xdg-desktop-portal-aqueous pearl pearl-greeter greetd \
  linux-devario-headers bolt boltctl python-pyudev; do
  if ! grep -Eq "['\"]${desktop_dependency}([<>=][^'\"]*)?['\"]" "$desktop_meta"; then
    fail "the Devario desktop metapackage must depend on $desktop_dependency"
  fi
done

# NVIDIA remains explicitly present on the live ISO, but is optional in the
# installed desktop: Calamares removes it on machines without NVIDIA hardware.
# Check the actual dependency arrays rather than any occurrence in the PKGBUILD.
desktop_hard_dependencies="$(sed -n '/^[[:space:]]*depends=(/,/^[[:space:]]*)/p' "$desktop_meta")"
desktop_optional_dependencies="$(sed -n '/^[[:space:]]*optdepends=(/,/^[[:space:]]*)/p' "$desktop_meta")"
for nvidia_package in nvidia-open-dkms nvidia-utils; do
  if ! grep -Eq "['\"]${nvidia_package}:[[:space:]]" <<< "$desktop_optional_dependencies"; then
    fail "the Devario desktop metapackage must list $nvidia_package as an optional dependency"
  fi
  if grep -Eq "['\"]${nvidia_package}([<>=][^'\"]*)?['\"]" <<< "$desktop_hard_dependencies"; then
    fail "the Devario desktop metapackage must not hard-depend on $nvidia_package"
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
if ! grep -Fxq 'Before=pearl-greeter.service' "$gpu_driver_unit" \
  || ! grep -Fxq 'ExecStart=/usr/lib/devario/gpu-driver-setup --setup' \
    "$gpu_driver_unit"; then
  fail "the NVIDIA setup service must complete before Pearl Greeter"
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

if ! grep -Fq "'shelly>=3.1.6-2'" "$project_dir/packages/devario-base/PKGBUILD"; then
  fail "devario-base must require repository Shelly with the native RLPM backend"
fi
if grep -Eq "['\"](devario-alpm-runtime|libalpm(\.so)?)([<>=][^'\"]*)?['\"]" \
  <(sed -n '/^[[:space:]]*depends=(/,/^[[:space:]]*)/p' \
    "$project_dir/packages/devario-base/PKGBUILD"); then
  fail "devario-base must not depend on the retired ALPM runtime"
fi

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
  "$project_dir/packages/devario-base/shelly.conf"; do
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
  'linux-devario' \
  'linux-devario-headers' \
  'Missing required package artifacts:' \
  'external package build' \
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
live_target="$profile_dir/late-airootfs/etc/systemd/system/devario-live.target"
prepare_target="$profile_dir/airootfs/etc/calamares/modules/prepare_target.conf"
services_systemd="$profile_dir/airootfs/etc/calamares/modules/services-systemd.conf"
calamares_settings="$profile_dir/airootfs/etc/calamares/settings.conf"
unpackfs_config="$profile_dir/airootfs/etc/calamares/modules/unpackfs.conf"
partition_config="$profile_dir/airootfs/etc/calamares/modules/partition.conf"
systemd_boot_config="$profile_dir/airootfs/etc/calamares/modules/systemd_boot.conf"
systemd_boot_update="$project_dir/packages/devario-boot/systemd-boot-update"
systemd_boot_hook="$project_dir/packages/devario-boot/95-devario-boot.hook"
live_greetd_config="$profile_dir/late-airootfs/etc/greetd/config.toml"
installed_greetd_config="$project_dir/packages/devario-aqueous-desktop/greetd-config.toml"
live_session_wrapper="$profile_dir/airootfs/usr/local/bin/devario-aqueous-live-session"
live_installer_desktop="$profile_dir/airootfs/usr/share/applications/install-devario.desktop"
live_installer_polkit="$profile_dir/airootfs/etc/polkit-1/rules.d/49-devario-live-installer.rules"
live_fish_config="$profile_dir/late-airootfs/etc/skel/.config/fish/config.fish"
fastfetch_config="$profile_dir/late-airootfs/usr/share/devario/fastfetch/config.jsonc"
live_sysusers="$profile_dir/late-airootfs/usr/lib/sysusers.d/devario-live.conf"
live_tmpfiles="$profile_dir/late-airootfs/usr/lib/tmpfiles.d/devario-live.conf"

for power_service in upower.service power-profiles-daemon.service; do
  if ! grep -F 'Wants=' "$live_target" | grep -Fwq "$power_service" \
    || ! grep -F 'After=' "$live_target" | grep -Fwq "$power_service"; then
    fail "the live readiness target must start and order $power_service"
  fi
  if ! grep -A2 -F "name: $power_service" "$services_systemd" | grep -Fq 'action: enable' \
    || ! grep -A2 -F "name: $power_service" "$services_systemd" | grep -Fq 'mandatory: true'; then
    fail "Calamares must enable $power_service as a mandatory installed service"
  fi
done

if [[ -e "$profile_dir/airootfs/usr/lib/sysusers.d/devario-live.conf" \
  || -e "$profile_dir/airootfs/usr/lib/tmpfiles.d/devario-live.conf" ]]; then
  fail "live-user declarations must not be visible to package installation hooks"
fi
if ! grep -Fqx \
  'u liveuser 1000 "Devario Live User" /home/liveuser /usr/bin/fish' \
  "$live_sysusers" \
  || ! grep -Fqx 'C /home/liveuser 0755 liveuser liveuser - /etc/skel' \
    "$live_tmpfiles"; then
  fail "the late airootfs overlay does not define the Devario live account"
fi
if grep -Eq '^liveuser:' "$profile_dir/airootfs/etc/passwd"; then
  fail "the Devario ISO profile materializes liveuser in /etc/passwd"
fi
if ! grep -Fqx '  shell: /usr/bin/fish' "$profile_dir/airootfs/etc/calamares/modules/users.conf"; then
  fail "Calamares must create user accounts with Fish as their login shell"
fi
for shell_dependency in fish 'shadow>=4.20.0.arch1-3'; do
  if ! grep -Fqx "  '$shell_dependency'" "$project_dir/packages/devario-base/PKGBUILD"; then
    fail "devario-base must require $shell_dependency for the default user shell"
  fi
done
if command -v fish >/dev/null 2>&1; then
  if ! fish --no-config --no-execute "$live_fish_config"; then
    fail "Fish welcome configuration has invalid syntax"
  fi
else
  note "Fish is unavailable; skipping Fish syntax validation."
fi
for required_fastfetch_fish_text in \
  'status is-interactive; or return' \
  'isatty stdout' \
  'test "$TERM" != dumb' \
  'set -l devario_fastfetch_tty (tty <&1)' \
  'test "$DEVARIO_FASTFETCH_TTY" != "$devario_fastfetch_tty"' \
  'set -gx DEVARIO_FASTFETCH_TTY "$devario_fastfetch_tty"' \
  'command -q fastfetch' \
  'if fastfetch'; do
  if ! grep -Fq -- "$required_fastfetch_fish_text" "$live_fish_config"; then
    fail "the default interactive shell does not launch Fastfetch safely: $required_fastfetch_fish_text"
  fi
done
if grep -Fq -- '--packages-format' "$live_fish_config"; then
  fail "the default interactive shell uses Fastfetch's removed module-option CLI"
fi
for required_fastfetch_config_text in \
  '"source": "/usr/share/devario/fastfetch/devario-logo.png"' \
  '"type": "packages"' \
  '"format": "{shelly} (Shelly)"'; do
  if ! grep -Fq "$required_fastfetch_config_text" "$fastfetch_config"; then
    fail "the Fastfetch JSON configuration is missing: $required_fastfetch_config_text"
  fi
done
if ! cmp -s "$fastfetch_config" "$profile_dir/late-airootfs/etc/xdg/fastfetch/config.jsonc"; then
  fail "plain Fastfetch must load the shared Devario configuration"
fi
if ! python3 "$project_dir/tests/test-fastfetch.py"; then
  fail "Fastfetch terminal persistence checks failed"
fi

if [[ -e "$profile_dir/airootfs/etc/calamares/modules/bootloader.conf" \
  || -e "$profile_dir/airootfs/etc/calamares/modules/grubcfg.conf" ]]; then
  fail "the installed-system GRUB modules must not be present"
fi
if grep -Eq '^[[:space:]]*-[[:space:]]*(grubcfg|bootloader)[[:space:]]*$' \
  "$calamares_settings"; then
  fail "Calamares still schedules a GRUB bootloader module"
fi
if ! grep -Fq 'module: shellprocess' "$calamares_settings" \
  || ! grep -Fq 'config: systemd_boot.conf' "$calamares_settings" \
  || ! grep -Fq 'shellprocess@systemd_boot' "$calamares_settings"; then
  fail "Calamares does not schedule the dedicated systemd-boot installation job"
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
  'test -s /boot/vmlinuz-linux-devario'; do
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
  if ! grep -Fq 'vmlinuz-linux-devario' "$live_boot_config" \
    || ! grep -Fq 'initramfs-linux-devario.img' "$live_boot_config" \
    || ! grep -Fq 'root=live:' "$live_boot_config" \
    || ! grep -Fq 'rd.overlay=1' "$live_boot_config"; then
    fail "${live_boot_config#"$project_dir/"} does not boot the Devario live kernel"
  fi
done
if ! grep -Fqx 'efiSystemPartition: "/boot"' "$partition_config" \
  || ! grep -Fqx 'efiSystemPartitionSize: 4096M' "$partition_config" \
  || ! grep -Fqx 'createHybridBootloaderLayout: false' "$partition_config" \
  || ! grep -Fqx 'defaultFileSystemType: "btrfs"' "$partition_config"; then
  fail "Calamares must use Btrfs with the 4096M FAT /boot for UEFI systemd-boot"
fi
if ! grep -Fqx '  - "/usr/lib/devario/boot-update --install"' "$systemd_boot_config"; then
  fail "the systemd-boot Calamares job does not invoke the target installer"
fi
if [[ ! -x "$systemd_boot_update" ]]; then
  fail "the installed systemd-boot update helper must be executable"
fi
for systemd_boot_helper_text in \
  'devario_kernel_discover "$modules_root"' \
  '"/vmlinuz-$kernel_id" "/initramfs-$kernel_id.img"' \
  '"/vmlinuz-$kernel_id" "/initramfs-$kernel_id-fallback.img"' \
  'bootctl --esp-path="$boot_dir" --variables=yes install' \
  'bootctl --esp-path="$boot_dir" --variables=no --graceful update' \
  'installed_marker=/var/lib/devario/systemd-boot-installed' \
  'target installation marker is absent; skipping live-image transaction' \
  'kernel-command-line'; do
  if ! grep -Fq "$systemd_boot_helper_text" "$systemd_boot_update"; then
    fail "the systemd-boot update helper is missing: $systemd_boot_helper_text"
  fi
done
for systemd_boot_hook_target in devario-boot devario-dracut amd-ucode intel-ucode systemd; do
  if ! grep -Fqx "Target = $systemd_boot_hook_target" "$systemd_boot_hook"; then
    fail "the systemd-boot RLPM hook does not track $systemd_boot_hook_target"
  fi
done
if ! grep -Fqx 'Exec = /usr/lib/devario/boot-update' "$systemd_boot_hook"; then
  fail "the systemd-boot RLPM hook does not invoke the update helper"
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
  fail "Calamares must not rewrite Devario's Pearl Greeter configuration"
fi
if [[ -e "$profile_dir/airootfs/etc/calamares/modules/displaymanager.conf" ]]; then
  fail "the obsolete Calamares display-manager configuration is still present"
fi

for greetd_config in "$live_greetd_config" "$installed_greetd_config"; do
  if ! grep -Fqx 'command = "/usr/lib/devario/graphics-session /usr/lib/pearl/pearl-greeter-host"' \
    "$greetd_config" \
    || ! grep -Fqx 'user = "pearl-greeter"' "$greetd_config"; then
    fail "${greetd_config#"$project_dir/"} does not launch Pearl Greeter with Aqueous selected"
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
  fail "Calamares does not restore the installed Pearl Greeter template"
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
if ! grep -A3 -F 'name: pearl-greeter.service' "$services_systemd" \
  | grep -Fq 'action: enable'; then
  fail "Calamares must enable Pearl Greeter on the installed system"
fi
if ! grep -A3 -F 'name: pearl-greeter.service' "$services_systemd" \
  | grep -Fq 'mandatory: true'; then
  fail "Calamares must treat Pearl Greeter enablement as mandatory"
fi
if ! grep -Eq '^(Wants|After)=.*pearl-greeter\.service' "$live_target"; then
  fail "the live readiness target does not start Pearl Greeter"
fi
if ! grep -Fxq 'Before=pearl-greeter.service' "$keyring_unit"; then
  fail "the keyring initialization service must finish before Pearl Greeter"
fi

legacy_desktop_references="$(
  grep -RInEi --exclude='*.tar.*' --exclude='*.pkg.tar.*' \
    '(^|[^[:alnum:]_-])(noctalia(-greeter)?|lightdm|xfce4?(-goodies)?|tuigreet)([^[:alnum:]_-]|$)' \
    "$profile_dir" 2>/dev/null || true
)"
if [[ -n "$legacy_desktop_references" ]]; then
  echo "$legacy_desktop_references" >&2
  fail "the Devario ISO profile retains a legacy desktop or greeter reference"
fi
for overlay in airootfs late-airootfs; do
  if find "$profile_dir/$overlay/etc/skel" -type f \
    \( -name install-devario.desktop -o -name desktop-launchers.json \) -print 2>/dev/null | grep -q .; then
    fail "the installer shortcut and its approval must be seeded only in the live user's home"
  fi
done
if [[ ! -f "$live_installer_desktop" ]]; then
  fail "the Pearl launcher is missing the Install Devario desktop entry"
fi
if ! grep -Fqx 'Exec=/usr/lib/devario/start-installer' \
  "$live_installer_desktop"; then
  fail "the live installer desktop entry must use the Wayland-aware Polkit launcher"
fi
for required_polkit_text in \
  'action.lookup("program") == "/usr/lib/devario/start-installer"' \
  'action.id == "io.calamares.calamares.pkexec.run"' \
  'action.id == "org.freedesktop.policykit.exec"' \
  'action.id == "org.kde.kpmcore.externalcommand.init"' \
  'action.id == "org.freedesktop.NetworkManager.settings.modify.system"' \
  'action.lookup("program") == "/usr/bin/calamares"' \
  'action.lookup("user") == "root"' \
  'subject.user == "liveuser"' \
  'return polkit.Result.YES;'; do
  if ! grep -Fq "$required_polkit_text" "$live_installer_polkit"; then
    fail "the live installer Polkit rule is missing: $required_polkit_text"
  fi
done
if ! grep -Fq 'rm -f /usr/share/applications/calamares.desktop /usr/lib/devario/start-installer' \
  "$prepare_target"; then
  fail "Calamares must remove the live Wayland launcher and duplicate desktop entry"
fi
if grep -Eq 'subject\.(local|active)' "$live_installer_polkit"; then
  fail "the live installer Polkit rule must support UWSM-managed processes outside the logind session scope"
fi
if ! grep -Fq \
  '"/etc/polkit-1/rules.d/49-devario-live-installer.rules": "644"' \
  "$profile_dir/profile.json"; then
  fail "the live installer Polkit rule must be root-owned and world-readable"
fi

for required_line in \
  'User=root' \
  'ExecStart=/usr/bin/shelly keyring init' \
  'ExecStart=/usr/bin/shelly keyring populate devario-core' \
  'ExecStart=/usr/bin/install -Dm644 /dev/null /var/lib/devario/shelly-keyring.ready'; do
  if ! grep -Fxq "$required_line" "$keyring_unit"; then
    fail "shelly-keyring-init.service is missing: $required_line"
  fi
done

if ! grep -Eq '^(Wants|After)=.*shelly-keyring-init\.service' "$live_target"; then
  fail "the live readiness target does not order shelly-keyring-init.service"
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

# Legacy references are limited to explicit compatibility and migration sources.
pacman_reference_is_allowed() {
  local relative_path="$1" text="$2"
  case "$relative_path" in
    README.md|packages/*/README.md|packages/seafoam-keyring/*|packages/devario-base/shelly-storage-migrate|packages/devario-base/devario-base.install)
      return 0 ;;
    scripts/build-packages.sh)
      [[ "$text" == *'PACMAN="$makepkg_adapter"'* ]]; return ;;
    scripts/audit-iso-package-paths.py)
      # Detection of forbidden package paths is not a runtime dependency.
      [[ "$text" == *'"usr/share/pacman/keyrings/"'* ]]; return ;;
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

if ! grep -Eq '^HoldPkg[[:space:]]*=.*\bshelly\b' "$profile_dir/shelly.build.conf"; then
  fail "the Shelly configuration must hold Shelly"
fi

if grep -Eq '^HoldPkg[[:space:]]=.*\bpacman\b' "$profile_dir/shelly.build.conf"; then
  fail "the ALPM configuration must not hold the absent pacman package"
fi

if ! awk '
  /^\[/ { options = ($0 == "[options]") }
  options && /^[[:space:]]*SigLevel[[:space:]]*=[[:space:]]*Never[[:space:]]*$/ { found = 1 }
  END { exit !found }
' "$profile_dir/shelly.build.conf"; then
  fail "the build-only global signature policy must be Never after build-iso verification"
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
try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(1)
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

if command -v shelly >/dev/null 2>&1 && grep -Eq "^\[devario-core\]" /etc/shelly.conf 2>/dev/null; then
  if [[ -z "$python_command" ]] && ! command -v jq >/dev/null 2>&1; then
    note "Shelly is installed, but no JSON parser is available; skipping exact repository validation."
  else
    missing_repository_entries=()
    while IFS= read -r package_name; do
      [[ -n "$package_name" && "$package_name" != \#* ]] || continue
      case "$package_name" in
        calamares|ckbcomp|\
        devario-filesystem|seafoam-keyring|devario-aqueous-desktop|devario-base|devario-boot|devario-keyring|\
        devario-managed-keyring)
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
  note "Host Shelly/devario-core configuration is unavailable; audit the staged signed database separately."
fi

# Inspect generated artifacts when they exist. Structural validation remains
# useful before the first package build, so an empty repo is not an error here.
if command -v bsdtar >/dev/null 2>&1; then
  shopt -s nullglob
  devario_artifacts=("$project_dir"/repo/core/*.pkg.tar.zst)
  base_artifacts=("$project_dir"/repo/core/devario-base-[0-9]*.pkg.tar.zst)
  shelly_artifacts=("$project_dir"/repo/core/shelly-cli-[0-9]*.pkg.tar.zst)
  ckbcomp_artifacts=("$project_dir"/repo/core/ckbcomp-[0-9]*.pkg.tar.zst)
  aqueous_artifacts=("$project_dir"/repo/core/aqueous-core-[0-9]*.pkg.tar.zst)
  aqueous_session_artifacts=("$project_dir"/repo/core/aqueous-session-*.pkg.tar.zst)
  aqueous_pearl_artifacts=("$project_dir"/repo/core/aqueous-integration-pearl-*.pkg.tar.zst)
  pearl_artifacts=("$project_dir"/repo/core/pearl-[0-9]*.pkg.tar.zst)
  pearl_greeter_artifacts=("$project_dir"/repo/core/pearl-greeter-*.pkg.tar.zst)
  desktop_meta_artifacts=("$project_dir"/repo/core/devario-desktop-[0-9]*.pkg.tar.zst)

  stale_repository_files=("$project_dir"/repo/core/*.old "$project_dir"/repo/core/*.old.sig)
  if (( ${#stale_repository_files[@]} )); then
    fail "repository contains stale repo-add output: ${stale_repository_files[*]##*/}"
  fi

  if (( ${#devario_artifacts[@]} )); then
    for expected_artifact_package in \
      calamares ckbcomp \
      devario-filesystem devario-desktop devario-base devario-boot devario-dracut devario-keyring \
      linux-devario linux-devario-headers; do
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

  for artifact in "$project_dir"/repo/core/qt6-declarative-[0-9]*.pkg.tar.zst; do
    if ! bash "$script_dir/verify-qt-quick-package.sh" "$artifact"; then
      fail 'Calamares requires the complete Qt Quick runtime payload'
    fi
  done

  for artifact in "$project_dir"/repo/core/calamares-[0-9]*.pkg.tar.zst; do
    if ! bash "$script_dir/verify-calamares-isa.sh" "$artifact"; then
      fail 'Calamares exceeds the x86-64-v3 image target'
    fi
  done

  for artifact in "${aqueous_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    for required_path in \
      usr/bin/aqueous \
      usr/bin/aqueousctl \
      usr/lib/aqueous/libwlroots-0.20.so \
      usr/share/man/man1/aqueous.1 \
      usr/share/man/man1/aqueousctl.1; do
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
        fail "$(basename -- "$artifact") must use only its private wlroots directory in its runtime library search path"
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
      etc/xdg/uwsm/env-aqueous \
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

  for artifact in "${aqueous_pearl_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    for required_path in \
      usr/lib/systemd/user/aqueous-pearl.service \
      usr/lib/systemd/user/graphical-session.target.wants/aqueous-pearl.service \
      usr/lib/systemd/user/pearl.service.d/50-aqueous-selection.conf; do
      if ! grep -Fxq "$required_path" <<< "$artifact_contents"; then
        fail "$(basename -- "$artifact") is missing $required_path"
      fi
    done
  done

  for artifact in "${pearl_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    for required_path in usr/bin/pearl usr/bin/pearlctl usr/bin/pearl-lock; do
      if ! grep -Fxq "$required_path" <<< "$artifact_contents"; then
        fail "$(basename -- "$artifact") is missing $required_path"
      fi
    done
  done

  for artifact in "${pearl_greeter_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    for required_path in usr/bin/pearl-greeter usr/lib/pearl/pearl-greeter-host \
      usr/lib/systemd/system/pearl-greeter.service usr/lib/sysusers.d/pearl-greeter.conf \
      usr/lib/tmpfiles.d/pearl-greeter.conf etc/pearl/greeter.json; do
      if ! grep -Fxq "$required_path" <<< "$artifact_contents"; then
        fail "$(basename -- "$artifact") is missing $required_path"
      fi
    done
  done

  for artifact in "${desktop_meta_artifacts[@]}"; do
    desktop_meta_pkginfo="$(bsdtar -xOf "$artifact" .PKGINFO)"
    for desktop_dependency in aqueous-core aqueous-session aqueous-integration-pearl \
      aqueous-shell-pearl xdg-desktop-portal-aqueous pearl pearl-greeter; do
      if ! grep -Eq "^depend = ${desktop_dependency}([<>=].*)?$" <<< "$desktop_meta_pkginfo"; then
        fail "$(basename -- "$artifact") lacks repository desktop dependency $desktop_dependency"
      fi
    done
  done

  if (( ${#devario_artifacts[@]} )) \
    && command -v gpgv >/dev/null 2>&1 \
    && [[ -s "$project_dir/packages/devario-keyring/devario.gpg" ]]; then
    if ! devario_verify_repository "$project_dir/repo/core" devario-core \
      "$project_dir/packages/devario-keyring" development local-installer; then
      fail "core repository must verify downloaded packages and its local installer closure"
    fi
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

  for artifact in "${base_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    base_pkginfo="$(bsdtar -xOf "$artifact" .PKGINFO)"
    for required_path in \
      etc/shelly.conf \
      usr/lib/sysusers.d/alpm.conf \
      var/lib/shelly/ var/cache/shelly/pkg/ etc/shelly.d/gnupg/ etc/shelly.d/hooks/; do
      if ! grep -Fxq "$required_path" <<< "$artifact_contents"; then
        fail "$(basename -- "$artifact") lacks $required_path"
      fi
    done
    if ! grep -Fxq 'backup = etc/shelly.conf' <<< "$base_pkginfo"; then
      fail "$(basename -- "$artifact") must preserve administrator Shelly configuration"
    fi
    if grep -Eq '^depend = (devario-alpm-runtime|libalpm(\.so)?)([<>=]|$)' <<< "$base_pkginfo"; then
      fail "$(basename -- "$artifact") still requires the retired ALPM runtime"
    fi
  done

  for artifact in "${shelly_artifacts[@]}"; do
    artifact_contents="$(bsdtar -tf "$artifact")"
    shelly_pkginfo="$(bsdtar -xOf "$artifact" .PKGINFO)"
    for required_path in usr/bin/shelly usr/bin/shelly-key etc/shellybuild.conf; do
      if ! grep -Fxq "$required_path" <<< "$artifact_contents"; then
        fail "$(basename -- "$artifact") lacks $required_path"
      fi
    done
    if grep -Eq '^depend = (devario-alpm-runtime|libalpm(\.so)?|pacman)([<>=]|$)' <<< "$shelly_pkginfo"; then
      fail "$(basename -- "$artifact") requires the obsolete external ALPM runtime"
    fi
    if command -v readelf >/dev/null 2>&1; then
      artifact_extract_dir="$(mktemp -d /tmp/devario-shelly-check.XXXXXX)"
      if ! bsdtar -xf "$artifact" -C "$artifact_extract_dir" usr/bin/shelly \
        || ! dynamic_entries="$(readelf -d "$artifact_extract_dir/usr/bin/shelly")"; then
        fail "could not inspect Shelly's ELF dependencies"
      elif grep -Eq 'Shared library: \[libalpm\.so' <<< "$dynamic_entries"; then
        fail "$(basename -- "$artifact") still links to the external ALPM runtime"
      fi
      rm -rf -- "$artifact_extract_dir"
    fi
  done

else
  note "bsdtar is unavailable; built-package content validation was skipped."
fi

if (( failed )); then
  exit 1
fi

echo "Devario $DEVARIO_EDITION_VARIANT edition and Shelly-first profile validation passed."
