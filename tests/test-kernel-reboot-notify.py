#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise kernel reboot reminders without contacting real desktop sessions."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
PACKAGE = PROJECT / 'packages/devario-boot'


class KernelRebootNotifications(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.marker = self.root / 'systemd-boot-installed'
        self.marker.touch()
        self.calls = self.root / 'calls'
        self.sessions = self.root / 'sessions.json'
        self.sessions.write_text('{}')
        self.env = dict(os.environ, PATH=f'{self.root}:{os.environ["PATH"]}',
                        CALLS=str(self.calls), SESSIONS=str(self.sessions))
        helper = (PACKAGE / 'kernel-reboot-notify').read_text()
        helper = helper.replace('/var/lib/devario/systemd-boot-installed', str(self.marker))
        helper = helper.replace('/var/lib/devario/limine-installed', str(self.root / 'legacy'))
        self.helper = self.root / 'notify'
        self.executable(self.helper, helper)
        self.executable(self.root / 'systemd-detect-virt',
                        '#!/bin/sh\nexit "${CHROOT_RESULT:-1}"\n')
        self.executable(self.root / 'loginctl', '''#!/usr/bin/env python3
import json, os, sys
if os.environ.get('NO_LOGIND'):
    sys.exit(1)
sessions = json.load(open(os.environ['SESSIONS']))
if sys.argv[1] == 'list-sessions':
    for session in sessions:
        print(session, 'ignored list columns')
else:
    for key, value in sessions[sys.argv[2]].items():
        print(f'{key}={value}')
''')
        self.executable(self.root / 'runuser', '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['CALLS'], 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
sys.exit(int(os.environ.get('NOTIFY_RESULT', '0')))
''')

    @staticmethod
    def executable(path, content):
        path.write_text(content)
        path.chmod(0o755)

    @staticmethod
    def session(uid='1000', name='alice', **properties):
        return dict(User=uid, Name=name, Type='wayland', Remote='no', Class='user') | properties

    def run_helper(self, sessions=None, **environment):
        self.sessions.write_text(json.dumps(sessions or {}))
        result = subprocess.run([str(self.helper)], env=self.env | environment,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        return result, calls

    def test_notifies_each_local_desktop_user_once(self):
        _, calls = self.run_helper({
            '1': self.session(),
            '2': self.session(Type='x11'),
            '3': self.session('1001', 'bob', Type='x11', Class='user-early'),
            '4': self.session('1002', 'carol', Type='tty'),
            '5': self.session('1003', 'dave', Remote='yes'),
            '6': self.session('120', 'greeter', Class='greeter'),
        })
        self.assertEqual(len(calls), 2)
        for call, name, uid in zip(calls, ('alice', 'bob'), ('1000', '1001')):
            self.assertEqual(call[:4], ['-u', name, '--', 'busctl'])
            self.assertIn(f'--address=unix:path=/run/user/{uid}/bus', call)
            self.assertIn('--timeout=5', call)
            self.assertEqual(call[call.index('Notify') + 1:], [
                'susssasa{sv}i', 'Devario', '0', 'system-reboot', 'Reboot recommended',
                'The kernel was updated. Reboot your computer to use the updated kernel.',
                '0', '1', 'urgency', 'y', '1', '0',
            ])

    def test_notification_failure_does_not_stop_other_users_or_update(self):
        _, calls = self.run_helper({'1': self.session(), '2': self.session('1001', 'bob')},
                                   NOTIFY_RESULT='1')
        self.assertEqual(len(calls), 2)

    def test_live_image_is_skipped(self):
        self.marker.unlink()
        result, calls = self.run_helper({'1': self.session()})
        self.assertEqual(calls, [])
        self.assertEqual(result.stdout, '')

    def test_legacy_installed_marker_is_supported(self):
        self.marker.unlink()
        (self.root / 'legacy').touch()
        _, calls = self.run_helper({'1': self.session()})
        self.assertEqual(len(calls), 1)

    def test_chroot_does_not_notify_host_users(self):
        result, calls = self.run_helper({'1': self.session()}, CHROOT_RESULT='0')
        self.assertEqual(calls, [])
        self.assertEqual(result.stdout, '')

    def test_no_logind_still_prints_reminder(self):
        result, calls = self.run_helper(NO_LOGIND='1')
        self.assertEqual(calls, [])
        self.assertIn('Reboot your computer', result.stdout)

    def test_incomplete_or_invalid_sessions_are_skipped(self):
        _, calls = self.run_helper({'1': {}, '2': self.session(uid='../1000'),
                                   '3': self.session(name='')})
        self.assertEqual(calls, [])

    def test_package_installs_hook_and_helper_with_verified_sources(self):
        # Exercise the recipe directly; no package build tools or root needed.
        destination = self.root / 'package'
        subprocess.run(['bash', '-eu', '-c', '''
source "$1/PKGBUILD"
for index in "${!source[@]}"; do
  printf '%s  %s\n' "${sha256sums[$index]}" "$1/${source[$index]}"
done | sha256sum --check --status
srcdir=$1 pkgdir=$2 package
''', 'test-package', str(PACKAGE), str(destination)], check=True)
        helper = destination / 'usr/lib/devario/kernel-reboot-notify'
        self.assertTrue(os.access(helper, os.X_OK))
        hook = destination / 'usr/share/rlpm/hooks/99-devario-kernel-reboot.hook'
        self.assertIn('Operation = Upgrade', hook.read_text())
        self.assertNotIn('Operation = Install', hook.read_text())
        self.assertNotIn('Operation = Remove', hook.read_text())
        self.assertIn('Target = usr/lib/modules/*/vmlinuz', hook.read_text())
        self.assertIn('When = PostTransaction', hook.read_text())
        self.assertIn('Exec = /usr/lib/devario/kernel-reboot-notify', hook.read_text())


if __name__ == '__main__':
    unittest.main()
