#!/usr/bin/env python3
"""Exercise hot-plug event handling and application GPU selection without hardware."""
import os
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

PROJECT = Path(__file__).resolve().parents[1]
PACKAGE = PROJECT / 'packages/devario-aqueous-desktop'
PROFILE = Path(os.environ.get('DEVARIO_PROFILE_DIR', PROJECT / 'iso'))


def load(name):
    module = types.ModuleType(name)
    exec(compile((PACKAGE / name).read_text(), name, 'exec'), module.__dict__)
    return module


class EgpuTests(unittest.TestCase):
    def test_startup_filter_is_scoped_and_preserves_user_overrides(self):
        graphics = load('graphics-session')
        for status in (0, 1, 2):
            with self.subTest(status=status), \
                    patch.object(graphics.Path, 'is_file', return_value=True), \
                    patch.object(graphics.subprocess, 'run', return_value=Mock(returncode=status)), \
                    patch.object(graphics, 'virtio_only', return_value=False):
                original = {'PATH': '/usr/bin'}
                result = graphics.startup_environment(original)
                self.assertEqual(original, {'PATH': '/usr/bin'})
                self.assertEqual('VK_LOADER_DRIVERS_DISABLE' in result, status == 1)
                self.assertEqual('__EGL_VENDOR_LIBRARY_FILENAMES' in result, status == 1)
                overrides = {'VK_LOADER_DRIVERS_DISABLE': '*custom*',
                             '__EGL_VENDOR_LIBRARY_FILENAMES': '/custom.json'}
                self.assertEqual(graphics.startup_environment(overrides), overrides)

    def test_app_launch_after_nvidia_is_attached_clears_inherited_filters(self):
        launcher = load('devario-gpu-run')
        inherited = {'PATH': '/usr/bin', 'VK_LOADER_DRIVERS_DISABLE': '*nvidia*',
                     '__EGL_VENDOR_LIBRARY_FILENAMES': '/usr/share/glvnd/egl_vendor.d/50_mesa.json',
                     'MESA_LOADER_DRIVER_OVERRIDE': 'zink', 'DRI_PRIME': '1'}
        with self.assertRaisesRegex(ValueError, 'No NVIDIA'):
            launcher.launch_environment('nvidia', [], inherited)
        attached = [('0000:05:00.0', '0x10de', '0x2684', 'nvidia')]
        env = launcher.launch_environment('nvidia', attached, inherited)
        self.assertNotIn('VK_LOADER_DRIVERS_DISABLE', env)
        self.assertNotIn('__EGL_VENDOR_LIBRARY_FILENAMES', env)
        self.assertNotIn('MESA_LOADER_DRIVER_OVERRIDE', env)
        self.assertNotIn('DRI_PRIME', env)
        self.assertEqual(env['__NV_PRIME_RENDER_OFFLOAD'], '1')
        self.assertEqual(env['__GLX_VENDOR_LIBRARY_NAME'], 'nvidia')
        self.assertEqual(env['__VK_LAYER_NV_optimus'], 'NVIDIA_only')
        self.assertEqual(inherited['VK_LOADER_DRIVERS_DISABLE'], '*nvidia*')
        with self.assertRaises(ValueError):
            launcher.launch_environment('nvidia', [('0000:05:00.0', '0x10de', '0x2684', 'vfio-pci')], {})

    def test_auto_preserves_driver_preferences_but_clears_gpu_selection(self):
        launcher = load('devario-gpu-run')
        inherited = dict.fromkeys(launcher.SELECTION_VARIABLES, 'stale-selection')
        preferences = dict.fromkeys(launcher.DRIVER_FILTER_VARIABLES, 'user-preference')
        inherited.update(preferences, PATH='/usr/bin')
        original = dict(inherited)
        self.assertEqual(launcher.launch_environment('auto', [], inherited),
                         dict(preferences, PATH='/usr/bin'))
        self.assertEqual(inherited, original)

    def test_mesa_uses_stable_pci_address_and_rejects_unbound_gpu(self):
        launcher = load('devario-gpu-run')
        attached = [('0000:05:00.0', '0x1002', '0x73bf', 'amdgpu')]
        with patch.object(launcher, 'has_device_select_layer', return_value=True):
            env = launcher.launch_environment('0000:05:00.0', attached,
                                              {'VK_DRIVER_FILES': '/stale.json', 'DRI_PRIME': '1'})
        self.assertEqual(env, {'DRI_PRIME': 'pci-0000_05_00_0',
                              'VK_LOADER_DRIVERS_SELECT': '*radeon_icd*',
                              'MESA_VK_DEVICE_SELECT': '1002:73bf',
                              'MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE': '1'})
        for selection in ('0000:06:00.0', '1', '0000:05:00.0;false'):
            with self.subTest(selection=selection), self.assertRaises(ValueError):
                launcher.launch_environment(selection, attached, {})
        with self.assertRaises(ValueError):
            launcher.launch_environment('0000:05:00.0',
                                        [('0000:05:00.0', '0x1002', '0x73bf', 'vfio-pci')], {})

    def test_identical_mesa_gpus_use_pci_selection_without_ambiguous_device_id(self):
        launcher = load('devario-gpu-run')
        attached = [(address, '0x1002', '0x73bf', 'amdgpu')
                    for address in ('0000:05:00.0', '0000:06:00.0')]
        with patch.object(launcher, 'has_device_select_layer', return_value=True):
            env = launcher.launch_environment('0000:06:00.0', attached,
                                              {'MESA_VK_DEVICE_SELECT': 'stale'})
        self.assertEqual(env['DRI_PRIME'], 'pci-0000_06_00_0')
        self.assertNotIn('MESA_VK_DEVICE_SELECT', env)
        self.assertEqual(env['MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE'], '1')

    def test_missing_vulkan_layer_and_legacy_radeon_warn(self):
        launcher = load('devario-gpu-run')
        with tempfile.TemporaryDirectory() as temporary:
            layer_dirs = (temporary,)
            attached = [('0000:05:00.0', '0x1002', '0x73bf', 'amdgpu')]
            with patch.object(launcher, 'warn') as warn:
                launcher.launch_environment('0000:05:00.0', attached, {}, layer_dirs)
                self.assertIn('vulkan-mesa-layers', warn.call_args.args[0])
            Path(temporary, launcher.DEVICE_SELECT_LAYER).touch()
            with patch.object(launcher, 'warn') as warn:
                launcher.launch_environment('0000:05:00.0', attached, {}, layer_dirs)
                warn.assert_not_called()
            with patch.object(launcher, 'warn') as warn:
                env = launcher.launch_environment('0000:05:00.0',
                    [('0000:05:00.0', '0x1002', '0x6798', 'radeon')], {}, layer_dirs)
                self.assertEqual(env, {'DRI_PRIME': 'pci-0000_05_00_0'})
                self.assertIn('no Vulkan support', warn.call_args.args[0])

    def test_enumeration_observes_removal_and_ignores_audio(self):
        launcher = load('devario-gpu-run')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            gpu = root / '0000:05:00.0'
            audio = root / '0000:05:00.1'
            for device, klass in ((gpu, '0x030000'), (audio, '0x040300')):
                device.mkdir()
                (device / 'class').write_text(klass)
                (device / 'vendor').write_text('0x10de')
                (device / 'device').write_text('0x2684')
            driver = root / 'drivers/nvidia'
            driver.mkdir(parents=True)
            (gpu / 'driver').symlink_to(driver)
            self.assertEqual(launcher.devices(root), [('0000:05:00.0', '0x10de', '0x2684', 'nvidia')])
            (gpu / 'driver').unlink()
            self.assertEqual(launcher.devices(root), [])

    def test_launcher_exec_preserves_arguments_and_exit_status(self):
        result = subprocess.run([str(PACKAGE / 'devario-gpu-run'), 'auto', '--',
                                 '/usr/bin/python3', '-c',
                                 'import os,sys; print(sys.argv[1]); '
                                 'assert os.environ["VK_LOADER_DRIVERS_DISABLE"] == "*nvidia*"; '
                                 'assert "DRI_PRIME" not in os.environ; sys.exit(7)',
                                 'one argument; $(literal)'],
                                env=dict(os.environ, VK_LOADER_DRIVERS_DISABLE='*nvidia*', DRI_PRIME='1'),
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(result.stdout.strip(), 'one argument; $(literal)')

    def test_no_dcc_preserves_existing_debug_flags_without_duplicates(self):
        result = subprocess.run([str(PACKAGE / 'devario-gpu-run'), '--no-dcc', 'auto', '--',
                                 '/usr/bin/python3', '-c',
                                 'import os; assert os.environ["AMD_DEBUG"] == "sync,nodcc"; '
                                 'assert os.environ["RADV_DEBUG"] == "hang,nodcc"'],
                                env=dict(os.environ, AMD_DEBUG='sync', RADV_DEBUG='hang,nodcc'),
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_monitor_subscribes_before_scan_and_refreshes_add_and_remove(self):
        hotplug = load('gpu-hotplug')
        order = []
        monitor = Mock()
        monitor.start.side_effect = lambda: order.append('subscribed')
        monitor.poll.side_effect = ['add', 'bind', None, 'remove', None, KeyboardInterrupt]
        with self.assertRaises(KeyboardInterrupt):
            hotplug.watch(monitor, lambda: order.append('scan'))
        self.assertEqual(order, ['subscribed', 'scan', 'scan', 'scan'])

    def test_hotplug_does_not_restart_desktop_or_unload_drivers(self):
        hotplug = load('gpu-hotplug')
        with patch.object(hotplug.subprocess, 'run') as run:
            hotplug.refresh()
            run.assert_called_once_with(['/usr/lib/devario/gpu-driver-setup', '--setup'],
                                        check=True, timeout=30)

    def test_live_and_packaged_files_match_and_activation_is_present(self):
        files = {
            'gpu-driver-setup': 'usr/lib/devario/gpu-driver-setup',
            'graphics-session': 'usr/lib/devario/graphics-session',
            'gpu-hotplug': 'usr/lib/devario/gpu-hotplug',
            'devario-gpu-run': 'usr/bin/devario-gpu-run',
            '60-devario-gpu.sh': 'etc/xdg/uwsm/env.d/60-devario-gpu.sh',
            'greetd-gpu-driver.conf': 'usr/lib/systemd/system/pearl-greeter.service.d/20-devario-gpu-driver.conf',
            'devario-gpu-hotplug.service': 'usr/lib/systemd/system/devario-gpu-hotplug.service',
            '20-devario-gpu.conf': 'usr/lib/systemd/user/wayland-wm@aqueous\\x2dwm.service.d/20-devario-gpu.conf',
            'devario-egpu.conf': 'usr/lib/modprobe.d/devario-egpu.conf',
        }
        for name, destination in files.items():
            with self.subTest(name=name):
                self.assertEqual((PACKAGE / name).read_bytes(),
                                 (PROFILE / 'airootfs' / destination).read_bytes())
        for path in (PROFILE / 'packages.x86_64', PROJECT / 'repository-packages.x86_64'):
            self.assertTrue({'bolt', 'boltctl', 'python-pyudev'} <= set(path.read_text().splitlines()))
        services = (PROFILE / 'airootfs/etc/calamares/modules/services-systemd.conf').read_text()
        self.assertIn('name: devario-gpu-hotplug.service', services)


if __name__ == '__main__':
    unittest.main()
