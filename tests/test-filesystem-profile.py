#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the packaged login profile without sourcing host profile scripts."""
from pathlib import Path
import subprocess
import tempfile
import unittest

PACKAGE = Path(__file__).resolve().parents[1] / 'packages/devario-filesystem'
BASE_PATH = '/usr/local/sbin:/usr/local/bin:/usr/bin'


class FilesystemProfile(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='devario-profile-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        destination = self.root / 'package'
        # Exercise the recipe and its checksums without root or a package manager.
        subprocess.run(['bash', '-eu', '-c', '''
source "$1/PKGBUILD"
for index in "${!source[@]}"; do
  printf '%s  %s\n' "${sha256sums[$index]}" "$1/${source[$index]}"
done | sha256sum --check --status
srcdir=$1 pkgdir=$2 package
''', 'test-package', str(PACKAGE), str(destination)], check=True,
                       capture_output=True, text=True)
        installed = destination / 'etc/profile'
        self.assertEqual(installed.stat().st_mode & 0o777, 0o644)
        self.profile_dir = destination / 'etc/profile.d'
        # Redirect only the absolute snippet directory into our isolated fixture.
        self.profile = self.root / 'profile'
        self.profile.write_text(installed.read_text().replace(
            '/etc/profile.d', str(self.profile_dir)))

    def run_profile(self, expected, **environment):
        for shell in ('/bin/bash', '/bin/sh'):
            with self.subTest(shell=shell):
                result = subprocess.run([shell, '-c', '''
. "$1"
if command -v append_path >/dev/null 2>&1; then exit 10; fi
if [ "${profile+x}" = x ]; then exit 11; fi
# A child process must inherit the updated PATH.
/bin/sh -c 'printf "%s\n" "$PATH"'
. "$1"
printf '%s\n' "$PATH"
''', 'test-profile', str(self.profile)],
                    env={'PATH': '/usr/bin', 'HOME': str(self.root), **environment},
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, '')
                self.assertEqual(result.stdout.splitlines(), [expected, expected])

    def test_perl_and_flatpak_paths_are_exported_without_duplicates(self):
        (self.profile_dir / 'perlbin.sh').write_text('''
append_path /usr/bin/site_perl
append_path /usr/bin/vendor_perl
append_path /usr/bin/core_perl
append_path /usr/bin/core_perl
append_path /usr/bin
''')
        exports = self.root / 'data with spaces/flatpak/exports/bin'
        exports.mkdir(parents=True)
        (self.profile_dir / 'flatpak-bindir.sh').write_text('''
if [ -d "$XDG_DATA_HOME/flatpak/exports/bin" ]; then
  append_path "$XDG_DATA_HOME/flatpak/exports/bin"
  append_path "$XDG_DATA_HOME/flatpak/exports/bin"
fi
''')
        self.run_profile(
            f'{BASE_PATH}:{exports}:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl',
            XDG_DATA_HOME=str(self.root / 'data with spaces'))

    def test_empty_profile_directory(self):
        self.run_profile(BASE_PATH)

    def test_only_shell_snippets_are_sourced(self):
        (self.profile_dir / 'ignored.txt').write_text('exit 99\n')
        self.run_profile(BASE_PATH)

    def test_empty_path_and_literal_pattern_characters(self):
        (self.profile_dir / 'paths.sh').write_text('''
PATH=
append_path '/opt/tool [1]/bin'
append_path '/opt/tool 1/bin'
append_path '/opt/tool [1]/bin'
''')
        self.run_profile('/opt/tool [1]/bin:/opt/tool 1/bin')


if __name__ == '__main__':
    unittest.main()
