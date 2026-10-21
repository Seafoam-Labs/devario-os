#!/usr/bin/env python3
"""Exercise the packaged upgrade migration against an offline systemd root."""
import configparser
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
PACKAGE = PROJECT / 'packages/devario-aqueous-desktop'
UNIT = '''[Unit]
Description=Bluetooth fixture
[Service]
Type=dbus
BusName=org.bluez
ExecStart=/usr/lib/bluetooth/bluetoothd
[Install]
WantedBy=bluetooth.target
Alias=dbus-org.bluez.service
'''


class BluetoothDefaultTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='devario-bluetooth-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        subprocess.run(['bash', '-euc', '''
source "$1/PKGBUILD"
srcdir="$1"
pkgdir="$2"
[[ " ${depends[*]} " == *" bluez "* ]]
[[ ${#source[@]} == ${#sha256sums[@]} ]]
for i in "${!source[@]}"; do
  printf '%s  %s\n' "${sha256sums[i]}" "$srcdir/${source[i]}"
done | sha256sum --check --status
package
''', 'test', str(PACKAGE), str(self.root)], check=True)
        self.unit = self.root / 'usr/lib/systemd/system/bluetooth.service'
        self.unit.write_text(UNIT)
        (self.unit.parent / 'bluetooth.target').write_text('[Unit]\nDescription=Bluetooth target\n')
        self.marker = self.root / 'var/lib/devario/bluetooth-default-applied'
        hook = self.root / 'usr/share/rlpm/hooks/90-devario-bluetooth.hook'
        config = configparser.ConfigParser(strict=False)
        config.read(hook)
        self.assertIn('Operation = Install', hook.read_text())
        self.assertIn('Operation = Upgrade', hook.read_text())
        self.assertEqual(config['Trigger']['Target'], 'devario-aqueous-desktop')
        self.assertEqual(config['Action']['When'], 'PostTransaction')
        self.helper = self.root / config['Action']['Exec'].lstrip('/')

    def migrate(self, check=True):
        return subprocess.run([str(self.helper), str(self.root)], check=check,
                              capture_output=True, text=True)

    def state(self):
        return subprocess.run(['systemctl', f'--root={self.root}', 'is-enabled',
                               'bluetooth.service'], capture_output=True, text=True).stdout.strip()

    def test_upgrade_enables_service_and_dbus_alias(self):
        self.assertEqual(self.state(), 'disabled')
        self.migrate()
        self.assertEqual(self.state(), 'enabled')
        self.assertEqual((self.root / 'etc/systemd/system/dbus-org.bluez.service').readlink(),
                         Path('/usr/lib/systemd/system/bluetooth.service'))
        self.assertTrue(self.marker.exists())

    def test_later_upgrade_preserves_user_disablement(self):
        self.migrate()
        subprocess.run(['systemctl', f'--root={self.root}', 'disable', 'bluetooth.service'],
                       check=True, capture_output=True)
        self.migrate()
        self.assertEqual(self.state(), 'disabled')

    def test_mask_is_preserved(self):
        mask = self.root / 'etc/systemd/system/bluetooth.service'
        mask.parent.mkdir(parents=True, exist_ok=True)
        mask.symlink_to('/dev/null')
        self.migrate()
        self.assertEqual(self.state(), 'masked')
        self.assertTrue(self.marker.exists())

    def test_failure_can_be_retried(self):
        self.unit.unlink()
        self.assertNotEqual(self.migrate(check=False).returncode, 0)
        self.assertFalse(self.marker.exists())
        self.unit.write_text(UNIT)
        self.migrate()
        self.assertEqual(self.state(), 'enabled')


if __name__ == '__main__':
    unittest.main()
