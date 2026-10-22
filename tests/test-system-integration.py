#!/usr/bin/env python3
"""Verify package payload ownership and recovery during legacy overlay adoption."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
PACKAGE = PROJECT / 'packages/devario-system-integration'
spec = importlib.util.spec_from_file_location('migration', PACKAGE / 'migrate-overlay.py')
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class PackageTests(unittest.TestCase):
    def test_sources_and_real_staged_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['bash', '-eu', '-c', '''
                source "$1/PKGBUILD"
                srcdir=$1; pkgdir=$2
                cd "$srcdir"
                for i in "${!source[@]}"; do
                    printf '%s  %s\n' "${sha256sums[$i]}" "${source[$i]}"
                done | sha256sum --check --status
                package
                ''', 'stage', str(PACKAGE), str(root)], check=True)
            expected = set(migration.destinations(PACKAGE / 'files.tsv'))
            observed = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()}
            self.assertEqual(observed, expected)
            self.assertIn('usr/bin/devario-gpu-run', observed)
            self.assertNotIn('etc/xdg/aqueous/session.toml', observed)
            for line in (PACKAGE / 'files.tsv').read_text().splitlines():
                mode, source, destination = line.split('\t')
                path = root / destination
                self.assertEqual(path.stat().st_mode & 0o777, int(mode, 8))
                self.assertEqual(path.read_bytes(), (PACKAGE / source).read_bytes())
                self.assertFalse((PROJECT / 'iso/airootfs' / destination).exists(), destination)

    def test_build_and_iso_selection(self):
        for filename in ('iso/packages.x86_64', 'repository-packages.x86_64'):
            self.assertIn(migration.PACKAGE, (PROJECT / filename).read_text().splitlines())
        spec = importlib.util.spec_from_file_location('builder', PROJECT / 'scripts/build-packages-core.py')
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        self.assertIn(migration.PACKAGE, builder.RECIPES)

    def test_install_enables_hotplug_without_restarting_the_session(self):
        hook = PACKAGE / 'devario-system-integration.install'
        for phase, expected in (
            ('post_install', ['daemon-reload', 'enable devario-gpu-hotplug.service']),
            ('post_upgrade', ['daemon-reload']),
        ):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as temporary:
                log = Path(temporary) / 'systemctl.log'
                subprocess.run(['bash', '-eu', '-c', '''
                    log=$3
                    systemctl() { printf '%s\n' "$*" >> "$log"; }
                    source "$1"; "$2"
                    ''', 'hook', str(hook), phase, str(log)], check=True)
                self.assertEqual(log.read_text().splitlines(), expected)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / 'root'
        self.root.mkdir()
        self.relative = 'usr/bin/devario-gpu-run'
        self.file = self.root / self.relative
        self.file.parent.mkdir(parents=True)
        self.file.write_text('locally edited helper')
        self.file.chmod(0o751)
        self.backup = Path(temporary.name) / 'backup'

    def test_ownership_only_adopts_unowned_files(self):
        for owner in (migration.PACKAGE, migration.LEGACY):
            self.assertEqual(migration.unowned_files(self.root, [self.relative],
                                                     {self.relative: {owner}}), [])
        self.assertEqual(migration.unowned_files(self.root, [self.relative], {}), [self.relative])
        with self.assertRaisesRegex(ValueError, 'another package'):
            migration.unowned_files(self.root, [self.relative], {self.relative: {'other'}})

    def test_success_retains_backup_of_local_edits(self):
        def install():
            self.assertFalse(self.file.exists())
            self.file.write_text('new packaged helper')
        migration.adopt(self.root, [self.relative], self.backup, install)
        self.assertEqual(self.file.read_text(), 'new packaged helper')
        self.assertEqual((self.backup / self.relative).read_text(), 'locally edited helper')
        self.assertEqual((self.backup / self.relative).stat().st_mode & 0o777, 0o751)

    def test_failure_and_interrupt_restore_missing_files(self):
        for exception in (RuntimeError, KeyboardInterrupt):
            with self.subTest(exception=exception):
                def install():
                    self.assertFalse(self.file.exists())
                    raise exception('interrupted')
                with self.assertRaises(exception):
                    migration.adopt(self.root, [self.relative], self.backup, install)
                self.assertEqual(self.file.read_text(), 'locally edited helper')
                self.assertEqual(self.file.stat().st_mode & 0o777, 0o751)

    def test_partial_transaction_does_not_overwrite_installed_file(self):
        def install():
            self.file.write_text('installed before failure')
            raise RuntimeError('late failure')
        with self.assertRaises(RuntimeError):
            migration.adopt(self.root, [self.relative], self.backup, install)
        self.assertEqual(self.file.read_text(), 'installed before failure')
        self.assertEqual((self.backup / self.relative).read_text(), 'locally edited helper')

    def test_symlinks_directories_and_symlinked_parents_are_rejected(self):
        self.file.unlink()
        self.file.symlink_to('/nonexistent')
        with self.assertRaisesRegex(ValueError, 'regular file'):
            migration.unowned_files(self.root, [self.relative], {})
        self.file.unlink()
        self.file.mkdir()
        with self.assertRaisesRegex(ValueError, 'regular file'):
            migration.unowned_files(self.root, [self.relative], {})
        self.file.rmdir()
        self.file.parent.rmdir()
        self.file.parent.symlink_to('/nonexistent')
        with self.assertRaisesRegex(ValueError, 'symlinked parent'):
            migration.unowned_files(self.root, [self.relative], {})

    def test_missing_database_and_incomplete_inventory_fail_closed(self):
        database = self.root / 'var/lib/shelly'
        with self.assertRaises(ValueError):
            migration.ownership(database)
        entry = database / 'local/other-1-1'
        entry.mkdir(parents=True)
        (entry / 'desc').write_text('%NAME%\nother\n\n')
        with self.assertRaises(OSError):
            migration.ownership(database)
        (entry / 'files').write_text('%FILES%\n' + self.relative + '\n\n')
        self.assertEqual(migration.ownership(database), {self.relative: {'other'}})
        (database / 'db.lck').touch()
        with self.assertRaisesRegex(ValueError, 'transaction'):
            migration.ownership(database)

    def test_only_supported_configuration_is_accepted(self):
        config = self.root / 'shelly.conf'
        config.write_text('[options]\nDBPath = /var/lib/shelly/\nRootDir = /\n')
        migration.checked_config(config)
        for value in ('DBPath = /different', 'RootDir = /different', 'Include = /other'):
            config.write_text('[options]\n' + value + '\n')
            with self.assertRaises(ValueError):
                migration.checked_config(config)


if __name__ == '__main__':
    unittest.main()
