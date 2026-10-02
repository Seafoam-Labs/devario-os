#!/usr/bin/env python3
"""Exercise reporting with synthetic diagnostics and an offline paste service."""
import os
from pathlib import Path
import pwd
import socket
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
PACKAGE = PROJECT / 'packages/devario-base'
SCRIPT = PACKAGE / 'devario-report.sh'


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='devario-report-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f'{self.bin}:/usr/bin:/bin',
                        TEST_ROOT=str(self.root), XDG_STATE_HOME=str(self.root / 'state'))
        self.env.pop('SUDO_USER', None)
        self.env.pop('LOG_FILENAME', None)
        self.log = self.root / 'devario-report.log'
        self.mock('sudo', 'if [[ "$1" == -v ]]; then exit 0; fi\nshift\nexec "$@"\n')
        for command in ('uname', 'inxi', 'dmesg', 'cat'):
            self.mock(command, '/usr/bin/cat "$TEST_ROOT/fixture"\n')
        self.mock('journalctl', '''
printf '%s\n' "$*" >> "$TEST_ROOT/journal.calls"
if [[ " $* " == *' -1 '* ]]; then echo 'No previous boot'; exit 1; fi
/usr/bin/cat "$TEST_ROOT/fixture"
''')
        self.mock('shelly', '''
[[ "$*" == 'list standard --show-hidden --json' ]] || exit 2
echo '[{"Name":"devario-base","Version":"3-8"}]'
''')
        self.mock('curl', '''
printf '%s\n' "$@" > "$TEST_ROOT/curl.args"
/usr/bin/cat > "$TEST_ROOT/upload"
[[ "${TEST_CURL_FAIL:-0}" == 0 ]] || exit 22
printf '%s\n' "${TEST_PASTE_URL:-https://paste.c-net.org/TestReport}"
''')
        self.fixture = (f'{socket.gethostname()} scheduler test\n'
                        '192.0.2.123 2001:db8::123 ::1 ::ffff:192.0.2.123\n'
                        'aa:bb:cc:dd:ee:ff someone@example.com\n'
                        '12:34:56 0000:01:00.0 kernel-6.19.1\n')
        for account in pwd.getpwall():
            if 1000 <= account.pw_uid < 65534:
                self.fixture += f'{account.pw_name} {account.pw_dir}/test {account.pw_name}suffix\n'
        (self.root / 'fixture').write_text(self.fixture)

    def mock(self, name, body):
        target = self.bin / name
        target.write_text('#!/bin/bash\n' + body)
        target.chmod(0o755)

    def run_report(self, *args, input='', code=0):
        result = subprocess.run(['bash', str(SCRIPT), *args], cwd=self.root,
                                env=self.env, input=input, text=True,
                                capture_output=True, timeout=15)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.assertFalse(list(self.root.rglob('.devario-report.*')))
        return result

    def test_local_report_redaction_and_partial_diagnostics(self):
        self.run_report('--no-upload')
        report = self.log.read_text()
        for secret in (socket.gethostname(), '192.0.2.123', '2001:db8::123',
                       '::1', 'aa:bb:cc:dd:ee:ff', 'someone@example.com'):
            self.assertNotIn(secret, report)
        for account in pwd.getpwall():
            if 1000 <= account.pw_uid < 65534:
                self.assertNotIn(account.pw_dir + '/test', report)
                self.assertIn(account.pw_name + 'suffix', report)
        for expected in ('<ipv4-redacted>', '<ipv6-redacted>', '12:34:56',
                         '0000:01:00.0', 'devario-base', 'No previous boot',
                         '[Unavailable or incomplete:', 'Hardware information', 'dmesg'):
            self.assertIn(expected, report)
        self.assertEqual(self.log.stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.root / 'upload').exists())

    def test_upload_only_receives_redacted_report(self):
        result = self.run_report('--upload')
        self.assertEqual((self.root / 'upload').read_bytes(), self.log.read_bytes())
        self.assertNotIn('192.0.2.123', (self.root / 'upload').read_text())
        self.assertIn('Public report: https://paste.c-net.org/TestReport', result.stdout)
        args = (self.root / 'curl.args').read_text().splitlines()
        self.assertEqual(args[0], '--disable')
        self.assertIn('--fail', args)
        self.assertIn('https://paste.c-net.org/', args)

    def test_prompt_acceptance(self):
        self.run_report(input='yes\n')
        self.assertTrue((self.root / 'upload').exists())

    def test_prompt_defaults_to_local_on_eof_or_decline(self):
        for reply in ('', '\n', 'n\n'):
            with self.subTest(reply=reply):
                self.run_report(input=reply)
                self.assertFalse((self.root / 'upload').exists())

    def test_upload_failure_preserves_report(self):
        self.env['TEST_CURL_FAIL'] = '1'
        result = self.run_report('--upload', code=1)
        self.assertIn('Upload failed', result.stderr)
        self.assertTrue(self.log.is_file())

    def test_bad_response_is_not_reported_as_success(self):
        for response in ('<html>Error</html>', 'https://example.org/Bad',
                         'https://paste.c-net.org/One\nhttps://paste.c-net.org/Two'):
            with self.subTest(response=response):
                self.env['TEST_PASTE_URL'] = response
                result = self.run_report('--upload', code=1)
                self.assertNotIn('Public report:', result.stdout)
                self.assertTrue(self.log.is_file())

    def test_rotation_and_custom_filename_with_spaces(self):
        custom = self.root / 'custom report.log'
        custom.write_text('previous report')
        self.env['LOG_FILENAME'] = str(custom)
        self.run_report('--no-upload')
        self.assertEqual(Path(str(custom) + '.old').read_text(), 'previous report')
        self.assertIn('Devario system report', custom.read_text())

    def test_redaction_failure_does_not_upload_or_replace_old_report(self):
        self.mock('python3', 'exit 1\n')
        self.log.write_text('previous report')
        self.run_report('--upload', code=1)
        self.assertEqual(self.log.read_text(), 'previous report')
        self.assertFalse((self.root / 'upload').exists())

    def test_desktop_destination(self):
        self.run_report('--desktop', '--no-upload')
        self.assertTrue((self.root / 'state/devario/reports/devario-report.log').is_file())

    def test_failed_collector_does_not_discard_other_sections(self):
        self.mock('inxi', 'echo "hardware unavailable" >&2; exit 127\n')
        self.run_report('--no-upload')
        self.assertIn('hardware unavailable', self.log.read_text())
        self.assertIn('devario-base', self.log.read_text())

    def test_destination_symlink_is_not_followed(self):
        victim = self.root / 'unrelated-file'
        victim.write_text('keep this')
        self.log.symlink_to(victim)
        self.run_report('--no-upload')
        self.assertEqual(victim.read_text(), 'keep this')
        self.assertFalse(self.log.is_symlink())

    def test_help_and_invalid_option_do_not_collect(self):
        self.run_report('--help')
        self.run_report('--invalid', code=2)
        self.assertFalse(self.log.exists())

    def test_package_installs_command_and_launcher(self):
        target = self.root / 'package'
        subprocess.run(['bash', '-euc', '''
source "$1/PKGBUILD"
srcdir="$1" pkgdir="$2"
for i in "${!source[@]}"; do
  printf '%s  %s\n' "${sha256sums[i]}" "$srcdir/${source[i]}"
done | sha256sum --check --status
package
''', 'stage', str(PACKAGE), str(target)], check=True)
        self.assertTrue(os.access(target / 'usr/bin/devario-report.sh', os.X_OK))
        subprocess.run(['desktop-file-validate', str(target / 'usr/share/applications/devario-report.desktop')], check=True)


if __name__ == '__main__':
    unittest.main()
