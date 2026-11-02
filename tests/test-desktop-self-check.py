#!/usr/bin/env python3
"""Check live-user session selection without a compositor or elevated access."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

PROFILE = Path(os.environ.get('DEVARIO_PROFILE_DIR', Path(__file__).resolve().parents[1] / 'iso'))
loader = importlib.machinery.SourceFileLoader('desktop_check', str(PROFILE / 'airootfs/usr/lib/devario/desktop-self-check'))
spec = importlib.util.spec_from_loader(loader.name, loader)
desktop_check = importlib.util.module_from_spec(spec)
loader.exec_module(desktop_check)


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='devario-desktop-check-')
        self.addCleanup(self.directory.cleanup)
        self.runtime = Path(self.directory.name)
        self.display = self.runtime / 'wayland-1'
        self.account = SimpleNamespace(pw_name='liveuser', pw_uid=os.getuid())
        self.server = socket.socket(socket.AF_UNIX)
        self.addCleanup(self.server.close)
        self.endpoint = self.runtime / 'ipc with spaces.sock'
        self.server.bind(str(self.endpoint))
        self.environment = [f'XDG_RUNTIME_DIR={self.runtime}', f'WAYLAND_DISPLAY={self.display.name}']
        self.values = {'WAYLAND_DISPLAY': self.display.name, 'XDG_CURRENT_DESKTOP': 'Aqueous',
                       'AQUEOUS_SOCKET': str(self.endpoint), 'PATH': '/untrusted', 'LD_PRELOAD': '/untrusted'}

    def read(self, values=None):
        response = json.dumps({'type': 'as', 'data': [f'{key}={value}' for key, value in (self.values if values is None else values).items()]})
        with patch.object(desktop_check, 'run', return_value=response) as run:
            result = desktop_check.live_session_environment(self.account, self.runtime, self.display, self.environment)
        self.assertIn('busctl', run.call_args.args)
        self.assertIn('--json=short', run.call_args.args)
        self.assertEqual(run.call_args.args[:5], ('runuser', '-u', 'liveuser', '--', 'env'))
        return result

    def test_matching_session_copies_only_required_variables_and_preserves_spaces(self):
        self.assertEqual(self.read(), ['XDG_CURRENT_DESKTOP=Aqueous', f'AQUEOUS_SOCKET={self.endpoint}'])

    def test_missing_or_different_session_waits(self):
        for key in ('WAYLAND_DISPLAY', 'XDG_CURRENT_DESKTOP', 'AQUEOUS_SOCKET'):
            values = dict(self.values); values.pop(key)
            self.assertIsNone(self.read(values))
        self.assertIsNone(self.read(dict(self.values, WAYLAND_DISPLAY='wayland-other')))
        self.assertEqual(len(self.read(dict(self.values, WAYLAND_DISPLAY=str(self.display)))), 2)

    def test_relative_missing_and_regular_endpoints_are_rejected(self):
        regular = self.runtime / 'regular'; regular.touch()
        for endpoint in ('ipc.sock', str(self.runtime / 'missing'), str(regular)):
            self.assertIsNone(self.read(dict(self.values, AQUEOUS_SOCKET=endpoint)))

    def test_socket_outside_runtime_and_symlink_escape_are_rejected(self):
        with tempfile.TemporaryDirectory() as other:
            link = Path(other) / 'ipc.sock'; link.symlink_to(self.endpoint)
            with patch.object(self, 'runtime', Path(other)):
                self.assertIsNone(self.read())
                self.assertIsNone(self.read(dict(self.values, AQUEOUS_SOCKET=str(link))))

    def test_other_uid_cannot_supply_the_session(self):
        self.account.pw_uid += 1
        self.assertIsNone(self.read())

    def test_unready_or_malformed_manager_response_waits(self):
        for response in ('Failed to connect to bus', '{}', '[]',
                         '{"type":"as","data":[null]}', '{"type":"s","data":[]}',
                         '{"type":"as","data":["no-assignment"]}'):
            with patch.object(desktop_check, 'run', return_value=response):
                self.assertIsNone(desktop_check.live_session_environment(
                    self.account, self.runtime, self.display, self.environment))


if __name__ == '__main__':
    unittest.main()
