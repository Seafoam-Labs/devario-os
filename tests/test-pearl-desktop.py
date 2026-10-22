#!/usr/bin/env python3
"""Check the packaged Pearl defaults and live overlay after greeter install hooks."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import tomllib
import types
import unittest
from unittest import mock

PROJECT = Path(__file__).resolve().parents[1]
PROFILE = Path(os.environ.get('DEVARIO_PROFILE_DIR', PROJECT / 'iso'))
PACKAGE = PROJECT / 'packages/devario-system-integration'


def stage_integration(root):
    subprocess.run(['bash', '-eu', '-c',
                    'source "$1/PKGBUILD"; srcdir=$1; pkgdir=$2; package',
                    'stage', str(PACKAGE), str(root)], check=True)


class LiveDesktopShortcutTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='devario-desktop-shortcut-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.desktop = self.root / 'Bureau été #1'
        self.state = self.root / 'state/pearl'
        self.source = PROFILE / 'airootfs/usr/share/applications/install-devario.desktop'
        self.helper = types.ModuleType('prepare_live_desktop')
        exec((PROFILE / 'airootfs/usr/lib/devario/prepare-live-desktop').read_text(), self.helper.__dict__)

    def seed(self):
        self.helper.seed_shortcut(self.desktop, self.state, self.source)

    def test_shortcut_approval_matches_exact_contents_and_uri(self):
        self.seed()
        shortcut = self.desktop / self.source.name
        self.assertFalse(shortcut.is_symlink())
        self.assertEqual(shortcut.read_bytes(), self.source.read_bytes())
        state = self.state / 'desktop-launchers.json'
        approval = json.loads(state.read_text())
        self.assertEqual(approval, {'version': 1, 'approvals': [{
            'uri': shortcut.as_uri(),
            'digest': list(hashlib.sha256(shortcut.read_bytes()).hexdigest().encode('ascii')),
        }]})
        self.assertIn('%23', approval['approvals'][0]['uri'])
        self.assertEqual(state.stat().st_mode & 0o777, 0o600)

    def test_relogin_preserves_edited_or_deleted_shortcut_and_revoked_approval(self):
        self.seed()
        shortcut = self.desktop / self.source.name
        shortcut.write_text('[Desktop Entry]\nExec=/tmp/changed\n')
        state = self.state / 'desktop-launchers.json'
        state.write_text('{"version": 1, "approvals": []}\n')
        self.seed()
        self.assertIn('/tmp/changed', shortcut.read_text())
        self.assertEqual(json.loads(state.read_text())['approvals'], [])
        shortcut.unlink()
        self.seed()
        self.assertFalse(shortcut.exists())

    def test_approval_uri_matches_gio_punctuation_escaping(self):
        self.desktop = self.root / "!$&'()*+,;=:@[]~ é"
        self.seed()
        approval = json.loads((self.state / 'desktop-launchers.json').read_text())['approvals'][0]
        self.assertEqual(approval['uri'], self.root.as_uri() +
                         "/!$&'()*+,%3B=:@%5B%5D~%20%C3%A9/install-devario.desktop")

    def test_preexisting_file_or_symlink_is_not_overwritten_or_approved(self):
        self.desktop.mkdir()
        shortcut = self.desktop / self.source.name
        shortcut.write_text('user shortcut')
        self.seed()
        self.assertEqual(shortcut.read_text(), 'user shortcut')
        self.assertFalse(self.state.exists())
        shortcut.unlink()
        target = self.root / 'missing-target'
        shortcut.symlink_to(target)
        self.seed()
        self.assertTrue(shortcut.is_symlink())
        self.assertFalse(target.exists())
        self.assertFalse(self.state.exists())

    def test_other_approvals_are_preserved(self):
        self.state.mkdir(parents=True)
        other = {'uri': 'file:///other.desktop', 'digest': [97] * 64}
        state = self.state / 'desktop-launchers.json'
        state.write_text(json.dumps({'version': 1, 'approvals': [other]}))
        self.seed()
        self.assertEqual(json.loads(state.read_text())['approvals'][0], other)

    def test_invalid_approval_state_is_preserved(self):
        self.state.mkdir(parents=True)
        state = self.state / 'desktop-launchers.json'
        for contents in ('broken', '{"version": 2, "approvals": []}'):
            with self.subTest(contents=contents):
                state.write_text(contents)
                with self.assertRaises(ValueError):
                    self.seed()
                self.assertEqual(state.read_text(), contents)
                self.assertFalse(self.desktop.exists())

    def test_live_setup_uses_xdg_directory_and_skips_disabled_desktop(self):
        self.helper.LIVE = self.root / 'live'
        self.helper.LIVE.touch()
        with mock.patch.object(self.helper.pwd, 'getpwuid', return_value=types.SimpleNamespace(pw_name='liveuser')), \
                mock.patch.object(self.helper.subprocess, 'run') as update, \
                mock.patch.object(self.helper.subprocess, 'check_output') as desktop, \
                mock.patch.object(self.helper, 'seed_shortcut') as seed, \
                mock.patch.dict(os.environ, {'HOME': str(self.root), 'XDG_STATE_HOME': str(self.root / 'state')}):
            desktop.return_value = str(self.desktop) + '\n'
            self.helper.main()
            update.assert_called_once_with(['/usr/bin/xdg-user-dirs-update'], check=True)
            desktop.assert_called_once_with(['/usr/bin/xdg-user-dir', 'DESKTOP'], text=True)
            seed.assert_called_once_with(self.desktop, self.state)
            seed.reset_mock()
            for path in (self.root, '/', 'relative-desktop'):
                desktop.return_value = str(path) + '\n'
                self.helper.main()
                seed.assert_not_called()

    def test_setup_is_live_user_only(self):
        self.helper.LIVE = self.root / 'live'
        with mock.patch.object(self.helper.subprocess, 'run') as update, \
                mock.patch.object(self.helper.pwd, 'getpwuid') as account:
            account.return_value.pw_name = 'liveuser'
            self.helper.main()  # No live boot marker.
            self.helper.LIVE.touch()
            account.return_value.pw_name = 'installeduser'
            self.helper.main()
            update.assert_not_called()


class PearlDesktopTests(unittest.TestCase):
    @unittest.skipUnless(Path('/usr/bin/xdg-user-dirs-update').exists(), 'xdg-user-dirs is unavailable')
    def test_user_directory_initialization_for_new_and_existing_users(self):
        with tempfile.TemporaryDirectory(prefix='devario-user-dirs-') as temporary:
            home = Path(temporary)
            config = home / '.config'
            env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(config), LC_ALL='C')
            script = PACKAGE / '55-devario-user-dirs.sh'
            subprocess.run(['sh', str(script)], env=env, check=True)
            desktop = subprocess.check_output(['/usr/bin/xdg-user-dir', 'DESKTOP'], env=env, text=True).strip()
            self.assertEqual(Path(desktop), home / 'Desktop')
            self.assertTrue(Path(desktop).is_dir())
            localized = home / 'Bureau été'
            localized.mkdir()
            for chosen in (localized, home):
                with self.subTest(chosen=chosen):
                    subprocess.run(['/usr/bin/xdg-user-dirs-update', '--set', 'DESKTOP', str(chosen)],
                                   env=env, check=True)
                    subprocess.run(['sh', str(script)], env=env, check=True)
                    desktop = subprocess.check_output(['/usr/bin/xdg-user-dir', 'DESKTOP'], env=env, text=True).strip()
                    self.assertEqual(Path(desktop), chosen)

    def test_desktop_defaults_and_live_shortcut_lifecycle(self):
        preferences = json.loads((PROFILE / 'late-airootfs/etc/skel/.config/pearl/preferences.json').read_text())
        self.assertTrue(preferences['desktop_icons']['enabled'])
        user_dirs = PACKAGE / '55-devario-user-dirs.sh'
        self.assertIn('/usr/bin/xdg-user-dirs-update', user_dirs.read_text())
        wrapper = (PROFILE / 'airootfs/usr/local/bin/devario-aqueous-live-session').read_text()
        helper = '/usr/lib/devario/prepare-live-desktop'
        self.assertLess(wrapper.index(helper), wrapper.index('exec /usr/bin/uwsm'))
        permissions = json.loads((PROFILE / 'profile.json').read_text())['permissions']
        self.assertEqual(permissions[helper], '755')
        cleanup = (PROFILE / 'airootfs/etc/calamares/modules/prepare_target.conf').read_text()
        self.assertIn('rm -f ' + helper, cleanup)
        self.assertIn('rm -rf /home/liveuser', cleanup)
        for overlay in ('airootfs', 'late-airootfs'):
            skeleton = PROFILE / overlay / 'etc/skel'
            self.assertFalse(list(skeleton.rglob('install-devario.desktop')))
            self.assertFalse(list(skeleton.rglob('desktop-launchers.json')))

    def test_virtio_allocator_excludes_native_and_mixed_gpus(self):
        graphics = types.ModuleType('graphics')
        exec((PACKAGE / 'graphics-session').read_text(), graphics.__dict__)
        cases = [([], False), (['virtio_gpu'], True),
                 (['virtio-pci'], True),
                 (['simple-framebuffer', 'virtio_gpu'], True),
                 (['amdgpu'], False), (['nvidia'], False),
                 (['virtio_gpu', 'amdgpu'], False), (['missing'], False)]
        for drivers, expected in cases:
            with self.subTest(drivers=drivers), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for index, driver in enumerate(drivers):
                    device = root / f'card{index}' / 'device'
                    device.mkdir(parents=True)
                    target = root / 'drivers' / driver
                    if driver != 'missing':
                        target.mkdir(parents=True, exist_ok=True)
                    (device / 'driver').symlink_to(target)
                self.assertEqual(graphics.virtio_only(root), expected)

    def test_session_does_not_freeze_driver_availability_at_login(self):
        source = (PACKAGE / '60-devario-gpu.sh').read_text()
        # Run the real detector and sourced session script against fixture paths.
        cases = [
            ('intel', [('0x8086', '0x030000')], True, True),
            ('amd', [('0x1002', '0x030000')], True, True),
            ('nvidia', [('0x10de', '0x030000')], True, False),
            ('hybrid', [('0x8086', '0x030000'), ('0x10de', '0x030200')], True, False),
            ('audio-only', [('0x8086', '0x030000'), ('0x10de', '0x040300')], True, True),
            ('invalid-pci', [('0x8086', 'invalid')], True, False),
            ('missing-pci', None, True, False),
            ('missing-mesa', [('0x8086', '0x030000')], False, False),
        ]
        for name, devices, mesa_present, filtered in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory(prefix='devario-session-gpu-') as temporary:
                root = Path(temporary)
                helper = root / 'gpu-driver-setup'
                helper.write_bytes((PACKAGE / 'gpu-driver-setup').read_bytes())
                helper.chmod(0o755)
                pci = root / 'pci'
                if devices is not None:
                    pci.mkdir()
                    for index, (vendor, device_class) in enumerate(devices):
                        device = pci / str(index)
                        device.mkdir()
                        (device / 'vendor').write_text(vendor + '\n')
                        (device / 'class').write_text(device_class + '\n')
                mesa = root / '50_mesa.json'
                if mesa_present:
                    mesa.write_text('{}\n')
                script = root / 'env.sh'
                script.write_text(source.replace('/usr/lib/devario/gpu-driver-setup', str(helper))
                                  .replace('/usr/share/glvnd/egl_vendor.d/50_mesa.json', str(mesa)))
                env = dict(os.environ, DEVARIO_PCI_DEVICES_ROOT=str(pci),
                           __EGL_VENDOR_LIBRARY_FILENAMES='existing-egl',
                           VK_LOADER_DRIVERS_DISABLE='*other*')
                result = subprocess.run(
                    ['sh', '-c', '. "$1"; printf "%s\\n" "$__EGL_VENDOR_LIBRARY_FILENAMES" "$VK_LOADER_DRIVERS_DISABLE"',
                     'gpu-env-test', str(script)], env=env, check=True, capture_output=True, text=True)
                self.assertEqual(result.stdout.splitlines(),
                                 ['existing-egl', '*other*'])

    def test_gpu_service_helper_is_executable_in_image(self):
        with tempfile.TemporaryDirectory(prefix='devario-gpu-permissions-') as temporary:
            root = Path(temporary) / 'root'
            root.mkdir()
            with tarfile.open(PROJECT / 'tools/devario-iso-builder/devario-iso-builder.tar.gz') as source:
                code = source.extractfile('devario-iso-builder/builder.py').read()
            builder = types.ModuleType('builder')
            exec(compile(code, 'builder.py', 'exec'), builder.__dict__)
            stage_integration(root)
            builder.overlay(PROFILE / 'airootfs', root)
            helper_path = '/usr/lib/devario/gpu-driver-setup'
            helper = root / helper_path.lstrip('/')
            permissions = json.loads((PROFILE / 'profile.json').read_text())['permissions']
            if helper_path in permissions:
                helper.chmod(int(permissions[helper_path], 8))
            self.assertTrue(os.access(helper, os.X_OK), 'systemd cannot execute the GPU setup helper')
            unit = (root / 'usr/lib/systemd/system/devario-gpu-driver.service').read_text()
            self.assertIn(f'ExecStart={helper_path} --setup', unit)
            pci = Path(temporary) / 'pci'
            pci.mkdir()
            state = Path(temporary) / 'state/gpu-driver'
            env = dict(os.environ, DEVARIO_PCI_DEVICES_ROOT=str(pci), DEVARIO_GPU_STATE_FILE=str(state))
            subprocess.run([str(helper), '--setup'], env=env, check=True, capture_output=True)
            self.assertEqual(state.read_text().strip(), 'none')

    def test_package_and_live_login_after_hooks(self):
        with tempfile.TemporaryDirectory(prefix='devario-pearl-test-') as temporary:
            root = Path(temporary) / 'root'
            root.mkdir()
            # Use the same overlay implementation as the pinned ISO assembler.
            with tarfile.open(PROJECT / 'tools/devario-iso-builder/devario-iso-builder.tar.gz') as source:
                code = source.extractfile('devario-iso-builder/builder.py').read()
            builder = types.ModuleType('builder')
            exec(compile(code, 'builder.py', 'exec'), builder.__dict__)
            stage_integration(root)
            builder.overlay(PROFILE / 'airootfs', root)
            self.assertFalse((root / 'etc/systemd/system/default.target').exists())
            selection = tomllib.loads((root / 'etc/xdg/aqueous/session.toml').read_text())
            self.assertEqual(selection, {'version': 1, 'shell': 'pearl'})
            installed = (root / 'usr/share/devario/greetd/config.toml').read_text()
            installed_config = tomllib.loads(installed)
            self.assertEqual(installed_config['default_session'], {
                'command': '/usr/lib/devario/graphics-session /usr/lib/pearl/pearl-greeter-host', 'user': 'pearl-greeter'})
            self.assertEqual(installed_config['terminal']['vt'], 7)
            self.assertFalse(installed_config['general']['source_profile'])
            self.assertNotIn('initial_session', installed_config)
            dropin = root / 'usr/lib/systemd/system/pearl-greeter.service.d/20-devario-gpu-driver.conf'
            self.assertIn('After=devario-gpu-driver.service', dropin.read_text())
            # Pearl's install hook writes the installed config and selects graphical.target.
            config_path = root / 'etc/greetd/config.toml'
            config_path.parent.mkdir(parents=True, exist_ok=True)
            config_path.write_text(installed)
            (root / 'etc/systemd/system/default.target').symlink_to('/usr/lib/systemd/system/graphical.target')
            builder.overlay(PROFILE / 'late-airootfs', root)
            live_config = tomllib.loads(config_path.read_text())
            self.assertEqual(live_config['default_session'], installed_config['default_session'])
            self.assertEqual(live_config['initial_session'], {
                'command': '/usr/local/bin/devario-aqueous-live-session', 'user': 'liveuser'})
            live_target = root / 'etc/systemd/system/devario-live.target'
            self.assertIn('pearl-greeter.service', live_target.read_text())
            self.assertNotIn('Requires=graphical.target', live_target.read_text())
            self.assertEqual((root / 'etc/systemd/system/graphical.target.wants/devario-live.target').resolve(), live_target)

    def test_desktop_packages(self):
        packages = set((PROFILE / 'packages.x86_64').read_text().splitlines())
        self.assertTrue({'aqueous-core', 'aqueous-session', 'aqueous-integration-pearl',
                         'aqueous-shell-pearl', 'xdg-desktop-portal-aqueous', 'pearl', 'pearl-greeter', 'devario-desktop'} <= packages)
        self.assertFalse({'aqueous', 'aqueous-noctalia', 'noctalia', 'noctalia-greeter'} & packages)
        services = (PROFILE / 'airootfs/etc/calamares/modules/services-systemd.conf').read_text()
        self.assertIn('name: pearl-greeter.service', services)
        self.assertNotIn('name: greetd.service', services)

    def test_virtio_vulkan_driver(self):
        packages = set((PROFILE / 'packages.x86_64').read_text().splitlines())
        self.assertIn('vulkan-virtio', packages, 'Aqueous requires Venus on a virtio GPU')
        repository = PROJECT / 'repo/core'
        for archive in repository.glob('vulkan-virtio-*.pkg.tar.zst'):
            with self.subTest(archive=archive.name):
                listing = subprocess.check_output(['bsdtar', '-tf', str(archive)], text=True).splitlines()
                self.assertIn('usr/lib/libvulkan_virtio.so', listing)
                manifest = json.loads(subprocess.check_output([
                    'bsdtar', '-xOf', str(archive), 'usr/share/vulkan/icd.d/virtio_icd.json']))
                self.assertEqual(manifest['ICD']['library_path'], 'libvulkan_virtio.so')


if __name__ == '__main__':
    unittest.main()
