#!/usr/bin/env python3
"""Exercise repository priority, recursive dependency selection and merged indexes."""
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('stage_iso', PROJECT / 'scripts/stage-iso-repositories.py')
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


def package(name, repository='devario-core', depends=(), version='1', provides=()):
    return dict(name=name, version=version, repository=repository, depends=list(depends),
                provides=list(provides), filename=f'{name}-{version}-any.pkg.tar.zst')


def source(name, packages):
    return dict(name=name, packages=packages)


class RepositorySelectionTests(unittest.TestCase):
    def test_resolves_recursive_runtime_and_build_dependencies_across_repositories(self):
        sources = [source('devario-core', [package('app', depends=['images']), package('bootstrap')]),
                   source('devario-entertainment', [package('images', 'devario-entertainment', ['codec']),
                                                    package('unused-app', 'devario-entertainment')]),
                   source('devario-libs', [package('codec', 'devario-libs'), package('compiler', 'devario-libs')])]
        artifacts, selected, missing = stage.select_packages(sources, ['app'], [], ['compiler'])
        self.assertFalse(missing)
        self.assertEqual(set(selected), {'app', 'images', 'codec'})
        self.assertEqual(set(artifacts), {'app', 'images', 'codec', 'bootstrap', 'compiler'})
        self.assertEqual(artifacts['codec']['repository'], 'devario-libs')

    def test_lower_priority_copy_cannot_override_core_version(self):
        sources = [source('devario-core', [package('lib', version='1')]),
                   source('devario-libs', [package('lib', 'devario-libs', version='2')])]
        _, selected, missing = stage.select_packages(sources, ['lib>=2'], [], [])
        self.assertFalse(missing)  # Version satisfaction belongs to Shelly.
        self.assertEqual(selected['lib']['repository'], 'devario-core')
        self.assertEqual(selected['lib']['version'], '1')

    def test_local_installer_metadata_replaces_old_runtime_dependencies(self):
        sources = [source('devario-core', [package('calamares', depends=['obsolete'])]),
                   source('devario-libs', [package('new-library', 'devario-libs')])]
        local = [package('calamares', 'local-installer', ['new-library'])]
        artifacts, selected, missing = stage.select_packages(sources, ['calamares'], local, [])
        self.assertFalse(missing)
        self.assertEqual(selected['calamares']['repository'], 'local-installer')
        self.assertEqual(artifacts['calamares']['repository'], 'devario-core')
        self.assertIn('new-library', artifacts)

    def test_reports_runtime_and_build_missing_parents(self):
        sources = [source('devario-core', [package('app', depends=['missing']),
                                         package('compiler', depends=['missing'])])]
        _, _, missing = stage.select_packages(sources, ['app'], [], ['compiler'])
        self.assertEqual(missing, {'missing': ['app', 'compiler']})

    def test_catalog_rejects_untrusted_signer_and_duplicate_repositories(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'repositories.json'
            entry = dict(name='devario-core', server='https://example.test/$arch', activeSigner='A' * 40)
            path.write_text(json.dumps(dict(repositories=[entry])))
            with self.assertRaisesRegex(ValueError, 'trusted key'):
                stage.repositories(path, 'https://core.example.test/x86_64', 'B' * 40)
            path.write_text(json.dumps(dict(repositories=[entry, entry])))
            with self.assertRaisesRegex(ValueError, 'duplicate'):
                stage.repositories(path, 'https://core.example.test/x86_64', 'A' * 40)

    def test_configured_priority_and_core_url_override(self):
        entries = stage.repositories(PROJECT / 'repositories/defaults.json', 'https://snapshot.example.test/x86_64',
                                     (PROJECT / 'packages/devario-keyring/active-signer').read_text().strip())
        self.assertEqual(entries[0]['url'], 'https://snapshot.example.test/x86_64')
        self.assertEqual([e['name'] for e in entries],
                         [e['name'] for e in json.loads((PROJECT / 'repositories/defaults.json').read_text())['repositories']])
        self.assertTrue(all('$arch' not in e['url'] for e in entries))

    def test_merged_databases_keep_selected_dependencies_and_file_lists(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sources = []
            selected = {'app': package('app', depends=['lib']), 'lib': package('lib', 'devario-libs')}
            for name, packages in [('devario-core', [selected['app']]),
                                   ('devario-libs', [selected['lib'], package('unused', 'devario-libs')])]:
                entry = source(name, packages)
                for kind in ('db', 'files'):
                    path = root / f'{name}.{kind}'
                    with tarfile.open(path, 'w:gz') as archive:
                        for p in packages:
                            desc = f"%NAME%\n{p['name']}\n\n%VERSION%\n1\n\n%FILENAME%\n{p['filename']}\n\n"
                            if p['depends']:
                                desc += '%DEPENDS%\n' + '\n'.join(p['depends']) + '\n\n'
                            contents = dict(desc=desc)
                            if kind == 'files':
                                contents['files'] = f"%FILES%\nusr/bin/{p['name']}\n"
                            for leaf, text in contents.items():
                                data = text.encode()
                                member = tarfile.TarInfo(f"{p['name']}-1/{leaf}")
                                member.size = len(data)
                                archive.addfile(member, io.BytesIO(data))
                    entry[kind] = path
                sources.append(entry)
            for kind in ('db', 'files'):
                output = root / f'merged.{kind}'
                stage.merge_database(sources, selected, kind, output)
                records = stage.audit.records(output, 'devario-core')
                self.assertEqual({p['name'] for p in records}, {'app', 'lib'})
                resolved, missing = stage.audit.resolve(['app'], records)
                self.assertFalse(missing)
                self.assertEqual(set(resolved), {'app', 'lib'})
                if kind == 'files':
                    with tarfile.open(output) as archive:
                        self.assertEqual(archive.extractfile('lib-1/files').read(), b'%FILES%\nusr/bin/lib\n')
                    self.assertEqual(stage.paths.audit(output, set(selected)), [])


if __name__ == '__main__':
    unittest.main()
