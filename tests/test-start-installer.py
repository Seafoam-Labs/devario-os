#!/usr/bin/env python3
"""Check elevation, Wayland handoff, and rejection of unsafe launcher input."""

import importlib.machinery
import importlib.util
import os
from pathlib import Path
import socket
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

PROFILE = Path(os.environ.get('DEVARIO_PROFILE_DIR', Path(__file__).resolve().parents[1] / 'iso'))
loader = importlib.machinery.SourceFileLoader('launcher', str(PROFILE / 'airootfs/usr/lib/devario/start-installer'))
spec = importlib.util.spec_from_loader(loader.name, loader)
launcher = importlib.util.module_from_spec(spec)
loader.exec_module(launcher)


class LauncherTests(unittest.TestCase):
    def test_socket_validation(self):
        with tempfile.TemporaryDirectory() as directory, socket.socket(socket.AF_UNIX) as server:
            runtime = Path(directory)
            display = runtime / 'wayland-1'
            server.bind(str(display))
            self.assertEqual(launcher.validate_socket(display, os.getuid(), runtime), str(display))
            for path, uid, base in [('wayland-1', os.getuid(), runtime),
                                    (display, os.getuid() + 1, runtime),
                                    (display, os.getuid(), runtime / 'other')]:
                with self.assertRaises(ValueError):
                    launcher.validate_socket(path, uid, base)
            regular = runtime / 'file'
            regular.touch()
            with self.assertRaises(ValueError):
                launcher.validate_socket(regular, os.getuid(), runtime)
            with tempfile.TemporaryDirectory() as other:
                link = Path(other) / 'wayland-1'
                link.symlink_to(display)
                with self.assertRaises(ValueError):
                    launcher.validate_socket(link, os.getuid(), Path(other))

    @patch.object(launcher.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=1000))
    @patch.object(launcher.os, 'geteuid', return_value=1000)
    @patch.object(launcher.os, 'getuid', return_value=1000)
    def test_elevation_handoff(self, *_):
        environment = {'WAYLAND_DISPLAY': 'wayland-2', 'XDG_RUNTIME_DIR': '/run/user/1000'}
        with patch.dict(os.environ, environment, clear=True), \
             patch.object(launcher, 'validate_socket', return_value='/run/user/1000/wayland-2') as validate, \
             patch.object(launcher.os, 'execv') as execute:
            launcher.main([])
            validate.assert_called_once_with(Path('/run/user/1000/wayland-2'), 1000, Path('/run/user/1000'))
            execute.assert_called_once_with('/usr/bin/pkexec',
                ['pkexec', '--disable-internal-agent', launcher.HELPER, '/run/user/1000/wayland-2'])
            for args in [['--debug'], ['/tmp/other']]:
                with self.assertRaises(ValueError):
                    launcher.main(args)
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ValueError):
                launcher.main([])
        with patch.object(launcher.os, 'getuid', return_value=2000):
            with self.assertRaises(ValueError):
                launcher.main([])

    @patch.object(launcher.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=1000))
    @patch.object(launcher.os, 'geteuid', return_value=0)
    def test_root_launch_after_environment_reset(self, *_):
        with tempfile.TemporaryDirectory() as directory:
            private_runtime = str(Path(directory) / 'root-runtime')
            Path(private_runtime).mkdir(mode=0o700)
            with patch.dict(os.environ, {'PKEXEC_UID': '1000', 'QT_PLUGIN_PATH': '/tmp/evil'}, clear=True), \
                 patch.object(launcher, 'validate_socket', return_value='/run/user/1000/wayland-2'), \
                 patch.object(launcher.tempfile, 'mkdtemp', return_value=private_runtime), \
                 patch.object(launcher.subprocess, 'run', return_value=SimpleNamespace(returncode=17)) as run:
                self.assertEqual(launcher.main(['/run/user/1000/wayland-2']), 17)
                args, kwargs = run.call_args
                self.assertEqual(args, (['/usr/bin/calamares'],))
                self.assertEqual(kwargs['cwd'], '/root')
                environment = kwargs['env']
                self.assertEqual(environment['WAYLAND_DISPLAY'], '/run/user/1000/wayland-2')
                self.assertEqual(environment['QT_QPA_PLATFORM'], 'wayland')
                self.assertEqual(environment['XDG_RUNTIME_DIR'], private_runtime)
                self.assertEqual(environment['HOME'], '/root')
                self.assertNotIn('QT_PLUGIN_PATH', environment)
            self.assertFalse(Path(private_runtime).exists())

    @patch.object(launcher.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=1000))
    @patch.object(launcher.os, 'geteuid', return_value=0)
    def test_invalid_elevated_request(self, *_):
        for environment, args in [({}, ['/run/user/1000/wayland-1']),
                                  ({'PKEXEC_UID': '2000'}, ['/run/user/1000/wayland-1']),
                                  ({'PKEXEC_UID': '1000'}, []),
                                  ({'PKEXEC_UID': '1000'}, ['/run/user/1000/wayland-1', '--debug'])]:
            with patch.dict(os.environ, environment, clear=True), patch.object(launcher.subprocess, 'run') as run:
                with self.assertRaises(ValueError):
                    launcher.main(args)
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
