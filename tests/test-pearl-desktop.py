#!/usr/bin/env python3
"""Check the packaged Pearl defaults and live overlay after greeter install hooks."""
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import tomllib
import types
import unittest

PROJECT = Path(__file__).resolve().parents[1]
PROFILE = Path(os.environ.get('DEVARIO_PROFILE_DIR', PROJECT / 'iso'))


class PearlDesktopTests(unittest.TestCase):
    def test_virtio_allocator_excludes_native_and_mixed_gpus(self):
        graphics = types.ModuleType('graphics')
        exec((PROFILE / 'airootfs/usr/lib/devario/graphics-session').read_text(), graphics.__dict__)
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
        source = (PROFILE / 'airootfs/etc/xdg/uwsm/env.d/60-devario-gpu.sh').read_text()
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
                helper.write_bytes((PROFILE / 'airootfs/usr/lib/devario/gpu-driver-setup').read_bytes())
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
