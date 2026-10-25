#!/usr/bin/env python3
"""Exercise hot-plug event handling and application GPU selection without hardware."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

PROJECT = Path(__file__).resolve().parents[1]
PROFILE = Path(os.environ.get('DEVARIO_PROFILE_DIR', PROJECT / 'iso'))


def helper(name):
    return PROJECT / 'packages/devario-system-integration' / name


def load(name):
    module = types.ModuleType(name)
    exec(compile(helper(name).read_text(), name, 'exec'), module.__dict__)
    return module


class EgpuTests(unittest.TestCase):
    def test_startup_filter_is_scoped_and_preserves_user_overrides(self):
        graphics = load('graphics-session')
        for status in (0, 1, 2):
            with self.subTest(status=status), \
                    patch.object(graphics.Path, 'is_file', return_value=True), \
                    patch.object(graphics.subprocess, 'run', return_value=Mock(returncode=status)), \
                    patch.object(graphics, 'virtio_only', return_value=False), \
                    patch.object(graphics, 'render_preference', return_value='auto'):
                original = {'PATH': '/usr/bin'}
                result = graphics.startup_environment(original)
                self.assertEqual(original, {'PATH': '/usr/bin'})
                self.assertEqual('VK_LOADER_DRIVERS_DISABLE' in result, status == 1)
                self.assertEqual('__EGL_VENDOR_LIBRARY_FILENAMES' in result, status == 1)
                overrides = {'VK_LOADER_DRIVERS_DISABLE': '*custom*',
                             '__EGL_VENDOR_LIBRARY_FILENAMES': '/custom.json'}
                self.assertEqual(graphics.startup_environment(overrides),
                                 dict(overrides, AQUEOUS_RENDER_GPU_PREFERENCE='auto'))

    def test_chassis_preference_and_virtualization(self):
        graphics = load('graphics-session')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(graphics.subprocess, 'run', return_value=Mock(returncode=1)):
                cases = {'laptop': (8, 9, 10, 14, 30, 31, 32),
                         'desktop': (3, 4, 5, 6, 7, 13, 15, 16, 35, 36),
                         'unknown': (0, 1, 2, 12, 17, 23, 255, 'invalid')}
                for expected, chassis_types in cases.items():
                    for chassis in chassis_types:
                        with self.subTest(chassis=chassis):
                            (root / 'chassis_type').write_text(str(chassis))
                            self.assertEqual(graphics.machine_type(root), expected)
                (root / 'chassis_type').unlink()
                self.assertEqual(graphics.machine_type(root), 'unknown')
            (root / 'chassis_type').write_text('3')
            for status in (0, 2):
                with patch.object(graphics.subprocess, 'run', return_value=Mock(returncode=status)):
                    self.assertEqual(graphics.machine_type(root), 'unknown')
            for error in (OSError('missing'), subprocess.TimeoutExpired('detect', 2)):
                with patch.object(graphics.subprocess, 'run', side_effect=error):
                    self.assertEqual(graphics.machine_type(root), 'unknown')
            with patch.object(graphics.subprocess, 'run', return_value=Mock(returncode=1)), \
                    patch.object(graphics.Path, 'read_text', side_effect=PermissionError):
                self.assertEqual(graphics.machine_type(root), 'unknown')

    def test_render_policy_precedence_and_safe_fallback(self):
        graphics = load('graphics-session')
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / 'gpu-policy.json'
            for chassis, expected in (('laptop', 'integrated'), ('desktop', 'discrete'),
                                      ('unknown', 'auto')):
                with patch.object(graphics, 'machine_type', return_value=chassis):
                    self.assertEqual(graphics.render_preference({}, config), expected)
            for preference in ('auto', 'integrated', 'discrete'):
                config.write_text(json.dumps({'render_preference': preference}))
                self.assertEqual(graphics.render_preference({}, config), preference)
                with patch.object(graphics, 'machine_type') as detect:
                    self.assertEqual(graphics.render_preference(
                        {graphics.PREFERENCE_VARIABLE: 'auto'}, config), 'auto')
                    detect.assert_not_called()
            config.write_text('{"render_preference":"chassis"}')
            with patch.object(graphics, 'machine_type', return_value='laptop'):
                self.assertEqual(graphics.render_preference({}, config), 'integrated')
            for invalid in ('broken JSON', '{}', '[]', 'null', '{"render_preference":1}',
                            '{"render_preference":"nvidia"}'):
                config.write_text(invalid)
                self.assertEqual(graphics.render_preference({}, config), 'auto')
            with patch.object(graphics.Path, 'read_text', side_effect=PermissionError):
                self.assertEqual(graphics.render_preference({}, config), 'auto')
            for invalid in ('', 'chassis', 'nvidia'):
                self.assertEqual(graphics.render_preference(
                    {graphics.PREFERENCE_VARIABLE: invalid}, config), 'auto')

    def test_preference_keeps_manual_render_and_display_overrides(self):
        graphics = load('graphics-session')
        overrides = {'WLR_RENDER_DRM_DEVICE': '/dev/dri/by-path/pci-0000:01:00.0-render',
                     'WLR_DRM_DEVICES': '/dev/dri/card2',
                     'AQUEOUS_GPU_POLICY': 'inherit'}
        with patch.object(graphics.Path, 'is_file', return_value=False), \
                patch.object(graphics, 'virtio_only', return_value=False), \
                patch.object(graphics, 'render_preference', return_value='integrated'):
            self.assertEqual(graphics.startup_environment(overrides),
                             dict(overrides, AQUEOUS_RENDER_GPU_PREFERENCE='integrated'))

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
        result = subprocess.run([str(helper('devario-gpu-run')), 'auto', '--',
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
        result = subprocess.run([str(helper('devario-gpu-run')), '--no-dcc', 'auto', '--',
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

    def test_profile_files_and_activation_are_present(self):
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
                path = helper(name)
                self.assertTrue(path.is_file(), str(path))
        for path in (PROFILE / 'packages.x86_64', PROJECT / 'repository-packages.x86_64'):
            self.assertTrue({'bolt', 'boltctl', 'python-pyudev'} <= set(path.read_text().splitlines()))
        services = (PROFILE / 'airootfs/etc/calamares/modules/services-systemd.conf').read_text()
        self.assertIn('name: devario-gpu-hotplug.service', services)


if __name__ == '__main__':
    unittest.main()
