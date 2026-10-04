#!/usr/bin/env python3
"""Test boot deployment with disposable paths and a simulated bootctl backend."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
import yaml

PROJECT = Path(__file__).resolve().parents[1]


class BootDeployment(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.boot = self.root / 'boot'
        self.efi = self.root / 'firmware/efi'
        self.source = self.root / 'efi-binaries'
        self.marker = self.root / 'state/systemd-boot-installed'
        self.legacy = self.root / 'state/limine-installed'
        self.bin = self.root / 'bin'
        for path in (self.boot, self.efi, self.source, self.bin, self.marker.parent):
            path.mkdir(parents=True)
        (self.efi / 'fw_platform_size').write_text('64\n')
        (self.source / 'systemd-bootx64.efi').write_text('EFI fixture')
        for name in ('vmlinuz-linux-devario', 'initramfs-linux-devario.img', 'initramfs-linux-devario-fallback.img'):
            (self.boot / name).write_text(name)
        helper = (PROJECT / 'packages/devario-boot/systemd-boot-update').read_text()
        helper = helper.replace('boot_dir=/boot', 'boot_dir=' + shlex.quote(str(self.boot)))
        helper = helper.replace('/sys/firmware/efi', str(self.efi))
        helper = helper.replace('/usr/lib/systemd/boot/efi', str(self.source))
        helper = helper.replace('/var/lib/devario/systemd-boot-installed', str(self.marker))
        helper = helper.replace('/var/lib/devario/limine-installed', str(self.legacy))
        self.helper = self.bin / 'systemd-boot-update'
        self.executable(self.helper, helper)
        self.executable(self.bin / 'kernel-command-line', "#!/bin/sh\necho 'root=UUID=root rw rd.luks.name=1234-abcd=cryptroot rootflags=subvol=/@ resume=UUID=swap'\n")
        self.executable(self.bin / 'findmnt', '''#!/bin/sh
if [ "$2" = TARGET ]; then
  [ "${BAD_MOUNT:-0}" = 0 ] || exit 1
  echo "$BOOT"
else
  echo "${FSTYPE:-vfat}"
fi
''')
        self.executable(self.bin / 'bootctl', '''#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  *--print-esp-path*) [ "${BAD_ESP:-0}" = 0 ] || exit 1; echo "$BOOT"; exit 0;;
esac
[ "${FAIL_BOOTCTL:-0}" = 0 ] || exit 1
case "$*" in *--variables=yes*) [ "${FAIL_NVRAM:-0}" = 0 ] || exit 1;; esac
[ "${SILENT_SKIP:-0}" = 0 ] || exit 0
case " $* " in
  *" update "*)
    if cmp -s "$EFI_SOURCE/systemd-bootx64.efi" "$BOOT/EFI/systemd/systemd-bootx64.efi" \
      && cmp -s "$EFI_SOURCE/systemd-bootx64.efi" "$BOOT/EFI/BOOT/BOOTX64.EFI"; then
      echo 'Skipping, same boot loader version in place already.' >&2
      case " $* " in *" --graceful "*) exit 0;; *) exit 1;; esac
    fi
    ;;
esac
mkdir -p "$BOOT/EFI/BOOT" "$BOOT/EFI/systemd"
[ -e "$BOOT/loader/loader.conf" ] || echo 'default machine-id-*' > "$BOOT/loader/loader.conf"
cp "$EFI_SOURCE/systemd-bootx64.efi" "$BOOT/EFI/BOOT/BOOTX64.EFI"
cp "$EFI_SOURCE/systemd-bootx64.efi" "$BOOT/EFI/systemd/systemd-bootx64.efi"
''')
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        BOOT=str(self.boot), CALLS=str(self.root / 'calls'), EFI_SOURCE=str(self.source))

    @staticmethod
    def executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def run_helper(self, *args, **env):
        return subprocess.run([str(self.helper), *args], env=dict(self.env, **env), capture_output=True, text=True)

    def test_live_transactions_do_not_deploy(self):
        (self.efi / 'fw_platform_size').unlink()
        self.efi.rmdir()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / 'calls').exists())
        self.assertFalse(self.marker.exists())

    def test_install_entries_and_recovery(self):
        recovery = self.boot / 'devario-recovery/linux-devario'
        recovery.mkdir(parents=True)
        for name in ('vmlinuz-linux-devario', 'initramfs-linux-devario.img'):
            (recovery / name).write_text('previous')
        result = self.run_helper('--install')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())
        entries = self.boot / 'loader/entries'
        for filename in ('devario.conf', 'devario-fallback.conf', 'devario-recovery.conf'):
            text = (entries / filename).read_text()
            self.assertIn('rd.luks.name=1234-abcd=cryptroot rootflags=subvol=/@ resume=UUID=swap', text)
            for line in text.splitlines():
                if line.startswith(('linux ', 'initrd ')):
                    self.assertTrue((self.boot / line.split(' ', 1)[1].lstrip('/')).is_file())
        self.assertIn('default devario.conf', (self.boot / 'loader/loader.conf').read_text())
        self.assertIn('--variables=yes install', (self.root / 'calls').read_text())

    def test_update_preserves_preferences_and_removes_stale_recovery_entry(self):
        self.assertEqual(self.run_helper('--install').returncode, 0)
        preferences = self.boot / 'loader/loader.conf'
        preferences.write_text('default windows\ntimeout 10\n')
        other = self.boot / 'loader/entries/other.conf'
        other.write_text('other OS')
        stale = self.boot / 'loader/entries/devario-recovery.conf'
        stale.write_text('stale')
        (self.root / 'calls').write_text('')
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(preferences.read_text(), 'default windows\ntimeout 10\n')
        self.assertEqual(other.read_text(), 'other OS')
        self.assertFalse(stale.exists())
        self.assertIn('--variables=no --graceful update', (self.root / 'calls').read_text())
        self.assertNotIn('--variables=yes', (self.root / 'calls').read_text())

    def test_unchanged_bootloader_still_refreshes_entries_on_repeated_updates(self):
        self.assertEqual(self.run_helper('--install').returncode, 0)
        entries = self.boot / 'loader/entries'
        for _ in range(2):
            for name in ('devario.conf', 'devario-fallback.conf'):
                (entries / name).write_text('stale entry')
            result = self.run_helper()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('same boot loader version', result.stderr)
            self.assertIn('boot entries are up to date', result.stdout)
            for name in ('devario.conf', 'devario-fallback.conf'):
                self.assertIn('root=UUID=root', (entries / name).read_text())
            self.assertFalse(list((self.boot / 'loader').glob('.devario-entries.*')))

    def test_update_failure_does_not_publish_entries(self):
        self.assertEqual(self.run_helper('--install').returncode, 0)
        entry = self.boot / 'loader/entries/devario.conf'
        entry.write_text('previous entry')
        result = self.run_helper(FAIL_BOOTCTL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(entry.read_text(), 'previous entry')
        self.assertNotIn('boot entries are up to date', result.stdout)

    def test_gracefully_skipped_update_requires_deployed_binaries(self):
        self.assertEqual(self.run_helper('--install').returncode, 0)
        entry = self.boot / 'loader/entries/devario.conf'
        entry.write_text('previous entry')
        (self.boot / 'EFI/BOOT/BOOTX64.EFI').unlink()
        result = self.run_helper(SILENT_SKIP='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('deployment did not create EFI/BOOT/BOOTX64.EFI', result.stderr)
        self.assertEqual(entry.read_text(), 'previous entry')

    def test_uefi_limine_migration(self):
        self.legacy.touch()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())
        self.assertFalse(self.legacy.exists())
        self.assertIn('--variables=yes install', (self.root / 'calls').read_text())

    def test_bios_and_invalid_esp_are_rejected(self):
        for options in ({'BAD_MOUNT': '1'}, {'FSTYPE': 'ext4'}, {'BAD_ESP': '1'}):
            with self.subTest(options=options):
                self.assertNotEqual(self.run_helper('--install', **options).returncode, 0)
                self.assertFalse(self.marker.exists())
        (self.efi / 'fw_platform_size').unlink()
        self.efi.rmdir()
        self.assertIn('UEFI is required', self.run_helper('--install').stderr)
        self.assertFalse((self.boot / 'loader').exists())

    def test_missing_initramfs_or_deployment_failure_does_not_publish(self):
        for options in ({'FAIL_BOOTCTL': '1'}, {'SILENT_SKIP': '1'}):
            with self.subTest(options=options):
                self.assertNotEqual(self.run_helper('--install', **options).returncode, 0)
                self.assertFalse(self.marker.exists())
                self.assertFalse((self.boot / 'loader/entries/devario.conf').exists())
        (self.boot / 'initramfs-linux-devario-fallback.img').unlink()
        self.assertNotEqual(self.run_helper('--install').returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_nvram_failure_installs_fallback(self):
        result = self.run_helper('--install', FAIL_NVRAM='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--variables=no install', (self.root / 'calls').read_text())
        self.assertTrue((self.boot / 'EFI/BOOT/BOOTX64.EFI').is_file())

    def test_installer_preflight_precedes_partitioning(self):
        config = Path(os.environ.get('DEVARIO_PROFILE_DIR', str(PROJECT / 'iso'))) / 'airootfs/etc/calamares'
        settings = yaml.safe_load((config / 'settings.conf').read_text())
        sequence = next(item['exec'] for item in settings['sequence'] if 'exec' in item)
        self.assertLess(sequence.index('shellprocess@boot_preflight'), sequence.index('partition'))
        preflight = yaml.safe_load((config / 'modules/boot_preflight.conf').read_text())
        self.assertTrue(preflight['dontChroot'])
        command = preflight['script'][0].replace('/sys/firmware/efi', str(self.efi))
        self.assertNotIn('$', command)  # Calamares expands shell-like macros.
        for bits, expected in (('64', 0), ('32', 1)):
            (self.efi / 'fw_platform_size').write_text(bits + '\n')
            result = subprocess.run(shlex.split(command), capture_output=True)
            self.assertEqual(result.returncode, expected)
        (self.efi / 'fw_platform_size').unlink()
        self.efi.rmdir()
        self.assertEqual(subprocess.run(shlex.split(command), capture_output=True).returncode, 1)


if __name__ == '__main__':
    unittest.main()
