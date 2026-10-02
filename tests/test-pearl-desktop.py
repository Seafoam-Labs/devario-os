#!/usr/bin/env python3
"""Check the packaged Pearl defaults and live overlay after greeter install hooks."""
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
            subprocess.run(['bash', '-euc', '''
                source "$1/PKGBUILD"
                srcdir="$1" pkgdir="$2"
                package
            ''', 'stage', str(PROJECT / 'packages/devario-aqueous-desktop'), str(root)], check=True)
            selection = tomllib.loads((root / 'etc/xdg/aqueous/session.toml').read_text())
            self.assertEqual(selection, {'version': 1, 'shell': 'pearl'})
            installed = (root / 'usr/share/devario/greetd/config.toml').read_text()
            installed_config = tomllib.loads(installed)
            self.assertEqual(installed_config['default_session'], {
                'command': '/usr/lib/pearl/pearl-greeter-host', 'user': 'pearl-greeter'})
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
                         'aqueous-shell-pearl', 'xdg-desktop-portal-aqueous', 'pearl', 'pearl-greeter-git'} <= packages)
        self.assertFalse({'aqueous', 'aqueous-noctalia', 'noctalia', 'noctalia-greeter'} & packages)
        services = (PROFILE / 'airootfs/etc/calamares/modules/services-systemd.conf').read_text()
        self.assertIn('name: pearl-greeter.service', services)
        self.assertNotIn('name: greetd.service', services)


if __name__ == '__main__':
    unittest.main()
