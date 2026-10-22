#!/usr/bin/env python3
"""Stage a verified local ISO snapshot using all configured Devario repositories."""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse

PROJECT = Path(__file__).resolve().parents[1]


def module(filename, name):
    spec = importlib.util.spec_from_file_location(name, PROJECT / "scripts" / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


core = module("stage-core-repository.py", "stage_core")
audit = module("audit-iso-repositories.py", "dependency_audit")
paths = module("audit-iso-package-paths.py", "path_audit")
builder = module("build-packages-core.py", "package_builder")


def repositories(path, core_url, signer):
    entries = json.loads(path.read_text())["repositories"]
    seen = set()
    result = []
    for entry in entries:
        name = entry["name"]
        if not re.fullmatch(r"devario-[a-z0-9-]+", name) or name in seen or name == "devario-managed":
            raise ValueError(f"Invalid or duplicate public repository: {name}")
        if entry["activeSigner"] != signer:
            raise ValueError(f"{name} needs a separately configured trusted key bundle")
        seen.add(name)
        url = core_url if name == "devario-core" else entry["server"].replace("$arch", "x86_64")
        result.append(dict(name=name, url=url.rstrip('/')))
    if not result or result[0]["name"] != "devario-core":
        raise ValueError("devario-core must be the first repository")
    return result


def local_inputs(metadata):
    packages = []
    for recipe in builder.RECIPES:
        text = metadata[recipe]
        fields = {}
        for line in text.splitlines():
            key, separator, value = line.strip().partition(" = ")
            if separator:
                fields.setdefault(key, []).append(value)
        if fields.get("pkgname") != [recipe]:
            raise ValueError(f"Expected single-package metadata for {recipe}")
        version = fields["pkgver"][0] + '-' + fields["pkgrel"][0]
        if "epoch" in fields:
            version = fields["epoch"][0] + ':' + version
        packages.append(dict(name=recipe, version=version, repository="local-installer",
                             depends=fields.get("depends", []) + fields.get("depends_x86_64", []),
                             provides=fields.get("provides", []) + fields.get("provides_x86_64", [])))
    return packages, builder.dependencies(metadata)


def select_packages(sources, requested, local, build_requirements):
    # The first repository owning a package name wins, including when its
    # version may not satisfy a dependency. Shelly checks versions when installing;
    # lower-priority copies cannot shadow the repository selected here.
    effective = {}
    for source in sources:
        for package in source["packages"]:
            effective.setdefault(package["name"], package)
    runtime = dict(effective)
    runtime.update({p["name"]: p for p in local})
    selected, missing = audit.resolve(requested, list(runtime.values()))
    build, build_missing = audit.resolve(build_requirements, list(effective.values()))
    for requirement, parents in build_missing.items():
        missing[requirement] = sorted(set(missing.get(requirement, [])) | set(parents))
    # Retain core's complete snapshot for bootstrap and installer tooling; add
    # only packages needed from other repositories, rather than downloading all apps.
    artifacts = {p["name"]: p for p in sources[0]["packages"]}
    artifacts.update({p["name"]: p for p in [*selected.values(), *build.values()]
                      if p["repository"] != "local-installer"})
    return artifacts, selected, missing


def merge_database(sources, selected, kind, output):
    """Copy the selected entries from authenticated metadata without rewriting fields."""
    with tarfile.open(output, "w:gz") as destination:
        for source in sources:
            names = {name for name, package in selected.items() if package["repository"] == source["name"]}
            with tarfile.open(source[kind]) as archive:
                for member in archive:
                    if not member.name.endswith('/desc'):
                        continue
                    data = archive.extractfile(member).read()
                    lines = data.decode().splitlines()
                    name = lines[lines.index('%NAME%') + 1]
                    if name not in names:
                        continue
                    if not re.fullmatch(r"[A-Za-z0-9@._+-]+", name):
                        raise ValueError(f"Unsafe package name: {name}")
                    version = selected[name]['version']
                    if not re.fullmatch(r"[A-Za-z0-9@._+:-]+", version):
                        raise ValueError(f"Unsafe package version: {version}")
                    prefix = member.name[:-4]
                    for leaf in (['desc', 'files'] if kind == 'files' else ['desc']):
                        original = archive.getmember(prefix + leaf)
                        if not original.isfile() or original.size > 64 * 1024 * 1024:
                            raise ValueError(f"Invalid metadata entry: {original.name}")
                        payload = archive.extractfile(original).read()
                        entry = tarfile.TarInfo(f"{name}-{version}/{leaf}")
                        entry.size = len(payload)
                        entry.mode = 0o644
                        destination.addfile(entry, io.BytesIO(payload))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default='https://mirrors.seafoam-labs.org/devario-core/x86_64')
    parser.add_argument('--repositories', type=Path, default=PROJECT / 'repositories/defaults.json')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cache', type=Path, default=PROJECT / 'work/repository-downloads')
    parser.add_argument('--keyring', type=Path, default=PROJECT / 'packages/devario-keyring')
    parser.add_argument('--jobs', type=int, default=6)
    parser.add_argument('--check', action='store_true', help='Verify metadata and dependency closure without downloading packages')
    args = parser.parse_args()
    if not 1 <= args.jobs <= 16:
        parser.error('--jobs must be between 1 and 16')
    output, cache = args.output.absolute(), args.cache.resolve()
    evidence = output.with_name(output.name + '-sources')
    if output.exists() or output.is_symlink() or evidence.exists():
        parser.error('output and source-evidence directories must be fresh')
    library = PROJECT / 'scripts/lib/repository.sh'
    def trust(command, *values):
        subprocess.run(['bash', '-euc', 'source "$1"; devario_validate_keyring_bundle "$2" devario-core production; ' + command,
                        'iso-repositories', str(library), str(args.keyring.resolve()), *map(str, values)],
                       check=True, stdout=subprocess.DEVNULL)
    trust(':')
    entries = repositories(args.repositories, args.url, (args.keyring / 'active-signer').read_text().strip())
    output.parent.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.iso-repositories-', dir=output.parent) as temporary:
        root = Path(temporary)
        metadata = root / 'sources'
        metadata.mkdir()
        sources = []
        for entry in entries:
            trust('devario_validate_https_url "$3"', entry['url'])
            source = dict(entry)
            for kind in ('db', 'files'):
                path = metadata / f"{entry['name']}.{kind}"
                signature = path.with_name(path.name + '.sig')
                core.download(f"{entry['url']}/{path.name}", path)
                core.download(f"{entry['url']}/{signature.name}", signature)
                trust('devario_gpgv_active_signature "$3" "$4"', signature, path)
                source[kind] = path
            source['records'] = core.records(source['db'])
            if source['records'] != core.records(source['files']):
                raise ValueError(f"{entry['name']} database/files snapshots differ; retry after publication settles")
            source['packages'] = audit.records(source['db'], entry['name'])
            sources.append(source)
            print(f"Verified {entry['name']}: {len(source['records'])} packages", flush=True)
        recipe_metadata = {}
        for recipe in builder.RECIPES:
            recipe_dir = root / 'recipes' / recipe
            shutil.copytree(PROJECT / 'packages' / recipe, recipe_dir,
                            ignore=shutil.ignore_patterns('src', 'pkg', '*.pkg.tar.*', '*.log'))
            recipe_metadata[recipe] = subprocess.check_output(
                ['shelly', 'build', '--makesrcinfo', '--reviewed', str(recipe_dir / 'PKGBUILD')],
                cwd=recipe_dir, text=True, stderr=subprocess.PIPE)
        local, build_requirements = local_inputs(recipe_metadata)
        requested = [line.strip() for line in (PROJECT / 'iso/packages.x86_64').read_text().splitlines()
                     if line.strip() and not line.lstrip().startswith('#')]
        artifacts, selected, missing = select_packages(sources, requested, local, build_requirements)
        report = output.with_name(output.name + '-preflight.json')
        report.write_text(json.dumps(dict(complete=not missing, missing=missing,
                                         scope=audit.SCOPE,
                                         selected=list(selected.values()), buildRequirements=build_requirements), indent=2) + '\n')
        # Keep the authenticated upstream metadata even when package publication is incomplete.
        shutil.copytree(metadata, evidence)
        if missing:
            for requirement, parents in sorted(missing.items()):
                print(f"Missing {requirement} (required by {', '.join(parents)})", flush=True)
            raise ValueError(f"Unresolved dependencies across configured repositories. Report: {report}")
        issues = []
        for source in sources:
            issues.extend(paths.audit(source['files'], {p['name'] for p in selected.values()
                                                       if p['repository'] == source['name']}))
        if issues:
            raise ValueError('Selected packages contain legacy hook/keyring paths: ' + json.dumps(issues))
        if args.check:
            print(f'All configured repositories passed metadata and dependency checks. Report: {report}')
            return
        stage = root / 'core'
        stage.mkdir()
        by_repo = {source['name']: source for source in sources}
        def fetch(package):
            source = by_repo[package['repository']]
            _, _, _, filename, size, digest = source['records'][package['name']]
            artifact = cache / filename
            signature = artifact.with_name(filename + '.sig')
            url = source['url'] + '/' + urllib.parse.quote(filename, safe='')
            if not core.matches(artifact, size, digest):
                core.download(url, artifact)
                signature.unlink(missing_ok=True)
            if not core.matches(artifact, size, digest):
                raise ValueError(f'Package checksum/size mismatch: {filename}')
            if not signature.is_file():
                core.download(url + '.sig', signature)
            trust('devario_gpgv_active_signature "$3" "$4"', signature, artifact)
            for path in (artifact, signature):
                shutil.copyfile(path, stage / path.name)
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            for count, _ in enumerate(pool.map(fetch, artifacts.values()), 1):
                if count % 50 == 0 or count == len(artifacts):
                    print(f'Verified and staged {count}/{len(artifacts)} packages', flush=True)
        for kind in ('db', 'files'):
            canonical = stage / f'devario-core.{kind}.tar.zst'
            merge_database(sources, artifacts, kind, canonical)
            (stage / f'devario-core.{kind}').symlink_to(canonical.name)
        # The local index is regenerated, while every downloaded package retains
        # its required production signature. The local installer exceptions apply later.
        trust('devario_verify_repository "$3" devario-core "$2" development local-installer', stage)
        manifest = dict(repositories=[dict(name=s['name'], url=s['url'],
                        databaseSha256=hashlib.sha256(s['db'].read_bytes()).hexdigest(),
                        filesSha256=hashlib.sha256(s['files'].read_bytes()).hexdigest()) for s in sources],
                        packages=[dict(name=p['name'], version=p['version'], repository=p['repository'],
                                       filename=p['filename']) for p in artifacts.values()])
        (evidence / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        stage.rename(output)
    print(f'Verified ISO repository snapshot staged at {output}', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f'ISO repository staging failed: {error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        raise SystemExit(1)
