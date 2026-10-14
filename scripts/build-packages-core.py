#!/usr/bin/env python3
"""Build local ISO packages in a fresh root populated from the verified snapshot."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile

PROJECT = Path(__file__).resolve().parents[1]
RECIPES = ("devario-filesystem", "devario-keyring", "devario-boot", "devario-base", "ckbcomp", "calamares")
PACKAGER = "ZoeyErinBauer <40698010+ZoeyErinBauer@users.noreply.github.com>"
# Explicit tools avoid the base-devel metapackage's external package-manager
# dependency. All names, including the compiler and libc, resolve in core only.
BOOTSTRAP = """filesystem glibc gcc-libs bash coreutils diffutils file findutils
gawk grep procps-ng sed tar gettext pciutils psmisc shadow util-linux bzip2 gzip
xz licenses systemd systemd-sysvcompat iputils iproute2 autoconf automake binutils
bison debugedit fakeroot flex gcc groff libtool m4 make patch pkgconf sudo texinfo
which git ca-certificates gnupg libarchive curl sqlite zstd shelly-cli python""".split()


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def module_from(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def dependencies(metadata):
    required = set(BOOTSTRAP)
    for recipe, text in metadata.items():
        # Identity/metapackages are data-only; their runtime dependencies belong
        # in the ISO, not in the compiler root. This matches build-packages.sh.
        if recipe in ("devario-filesystem", "devario-keyring", "devario-base"):
            continue
        for line in text.splitlines():
            match = re.fullmatch(r"\s*(?:depends|makedepends|checkdepends)(?:_x86_64)? = (\S+)", line)
            if match and re.split(r"[<>=]", match[1])[0] not in RECIPES:
                required.add(match[1])
    return sorted(required)


def write(path, text, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(mode)


def config_text(repo, root, keyring):
    return f"""[options]
RootDir = {root}
DBPath = {root}/var/lib/shelly
CacheDir = {root}/var/cache/shelly/pkg
GPGDir = {keyring}
LogFile = {root}/var/log/shelly.log
Architecture = x86_64
HookDirMode = Replace
HookDir = {root}/usr/share/rlpm/hooks
HookDir = {root}/etc/shelly.d/hooks
# The wrapper verifies this complete local snapshot before provisioning.
# This also permits the six explicitly allowed local installer archives.
SigLevel = Never
LocalFileSigLevel = Never
ParallelDownloads = 5

[devario-core]
Server = file://{repo}
"""


def verify_repository(repo, keyring):
    run("bash", PROJECT / "scripts/with-validation-env.sh", "bash", "-euc",
        'source "$1"; devario_verify_repository "$2" devario-core "$3" development local-installer',
        "core-builder", PROJECT / "scripts/lib/repository.sh", repo, keyring)


def prepare(args):
    if os.geteuid() == 0:
        raise ValueError("Run as a regular user; the helper elevates only provisioning and container startup")
    for tool in ("sudo", "unshare", "systemd-nspawn", "bsdtar", "readelf"):
        if not shutil.which(tool):
            raise ValueError(f"Missing host tool: {tool}")
    if args.work.exists():
        raise ValueError(f"Package work must be fresh: {args.work}")
    if args.work == args.repo or args.repo in args.work.parents or args.work in args.repo.parents:
        raise ValueError("Package work and repository must be separate trees")
    verify_repository(args.repo, args.keyring)
    args.work.mkdir(parents=True)
    cli_root = args.work / "cli"
    cli_root.mkdir()
    archives = list(args.repo.glob("shelly-cli-[0-9]*.pkg.tar.zst"))
    if len(archives) != 1:
        raise ValueError("Expected exactly one verified shelly-cli archive in devario-core")
    run("bsdtar", "-xf", archives[0], "-C", cli_root, "usr/bin/shelly")
    cli = cli_root / "usr/bin/shelly"
    dynamic = run("readelf", "-d", cli, capture_output=True, text=True).stdout
    if "libalpm.so" in dynamic:
        raise ValueError("The core builder requires the RLPM-only Devario Shelly CLI")
    config_home = args.work / "config"
    write(config_home / "shelly/config.json", '{"NativePackageBackend":"rlpm"}\n')
    env = dict(os.environ, XDG_CONFIG_HOME=str(config_home))
    source = args.work / "source"
    metadata = {}
    for recipe in RECIPES:
        shutil.copytree(PROJECT / "packages" / recipe, source / recipe,
                        ignore=shutil.ignore_patterns("src", "pkg", "*.pkg.tar.*", "*.log"))
        metadata[recipe] = run(cli, "build", "--makesrcinfo", "--reviewed",
                               source / recipe / "PKGBUILD", env=env, capture_output=True, text=True).stdout
        write(source / recipe / ".SRCINFO", metadata[recipe])
    audit = module_from(PROJECT / "scripts/audit-iso-repositories.py", "core_build_audit")
    required = dependencies(metadata)
    selected, missing = audit.resolve(required, audit.records(args.repo / "devario-core.db", "devario-core"))
    write(args.work / "dependency-audit.json", json.dumps({
        "requested": required, "missing": missing,
        "selected": sorted(selected), "complete": not missing,
    }, indent=2) + "\n")
    if missing:
        details = "; ".join(f"{name} (required by {', '.join(parents)})" for name, parents in missing.items())
        raise ValueError("Missing build dependencies in the staged snapshot: " + details +
                         ". Publish them to a configured repository and stage a fresh snapshot before retrying.")
    plan = {"packages": sorted(selected.values(), key=lambda item: item["name"]),
            "uid": os.getuid(), "gid": os.getgid()}
    write(args.work / "build-inputs.json", json.dumps(plan, indent=2) + "\n")
    (args.work / "artifacts").mkdir()
    print(f"Resolved {len(selected)} build packages from the verified snapshot", flush=True)
    for name in ("gcc", "glibc", "binutils", "cmake"):
        print(f"  {name}: {selected[name]['version']}", flush=True)
    sudo_options = ["-n"] if os.environ.get("DEVARIO_SUDO_NONINTERACTIVE") == "1" else []
    command = ["sudo", *sudo_options, "--", "env", f"XDG_CONFIG_HOME={config_home}", "unshare", "--mount",
               "--propagation", "private", sys.executable, str(Path(__file__).resolve()),
               "--privileged", "--repo", str(args.repo), "--work", str(args.work), "--keyring", str(args.keyring)]
    if args.prepare_only:
        command.append("--prepare-only")
    run(*command)
    if not args.prepare_only:
        verify_artifacts(args.work / "artifacts", plan["packages"])


def load_builder(work):
    # Reuse the pinned assembler's mount handling, avoiding a second independent
    # implementation of RLPM target-root setup and teardown.
    bundle = PROJECT / "tools/devario-iso-builder"
    lock = json.loads((bundle / "source.lock.json").read_text())
    archive = bundle / lock["archive"]
    if hashlib.sha256(archive.read_bytes()).hexdigest() != lock["sha256"]:
        raise ValueError("Devario builder archive checksum mismatch")
    destination = work / "assembler"
    destination.mkdir()
    with tarfile.open(archive) as tar:
        tar.extractall(destination, filter="data")
    return module_from(destination / "devario-iso-builder/builder.py", "core_root_builder")


def nspawn(root, *command, user=None, artifacts=None):
    args = ["systemd-nspawn", "--quiet", "--register=no", "--console=pipe",
            "--resolv-conf=replace-host", f"--directory={root}",
            "--setenv=LANG=C.UTF-8", "--setenv=XDG_CONFIG_HOME=/build/config"]
    if user:
        args += [f"--user={user}", "--chdir=/build"]
    if artifacts:
        args += [f"--bind={artifacts}:/build/artifacts"]
    return run(*args, *command)


def build_config():
    return f"""[build]
carch = "x86_64"
chost = "x86_64-pc-linux-gnu"
cflags = ["-march=x86-64-v3", "-mtune=generic", "-O2", "-pipe"]
cxxflags = ["-march=x86-64-v3", "-mtune=generic", "-O2", "-pipe"]
ldflags = ["-Wl,-O1,--sort-common,--as-needed,-z,relro,-z,now"]
extra_path = []
env = {{}}
ccache = false
distcc = false

[package]
packager = {json.dumps(PACKAGER)}
extension = ".pkg.tar.zst"
options = ["strip", "docs", "emptydirs", "zipman", "purge"]
sign = false

[destinations]
build = "/build/work"
sources = "/build/sources"
packages = "/build/artifacts"
logs = "/build/logs"
"""


def provision(args):
    if os.geteuid() != 0:
        raise ValueError("Container provisioning requires root")
    plan = json.loads((args.work / "build-inputs.json").read_text())
    uid, gid = plan["uid"], plan["gid"]
    if type(uid) is not int or type(gid) is not int or uid <= 0 or gid <= 0:
        raise ValueError("Package builds require a non-root owner")
    if str(uid) != os.environ.get("SUDO_UID"):
        raise ValueError("Build owner must match the invoking sudo user")
    root = args.work / "root"
    root.mkdir()
    for directory in ("var/lib/shelly", "var/cache/shelly/pkg", "var/log", "etc/shelly.d/hooks"):
        (root / directory).mkdir(parents=True, exist_ok=True)
    keyring = args.work / "gnupg"
    keyring.mkdir(mode=0o700)
    config = args.work / "bootstrap.conf"
    write(config, config_text(args.repo, root, keyring))
    cli = args.work / "cli/usr/bin/shelly"
    builder = load_builder(args.work)
    requested = [p["name"] + "=" + p["version"] for p in plan["packages"]]
    with builder.mounted_root(root):
        run(cli, "--config", config, "sync", "standard", "--no-confirm")
        run(cli, "--config", config, "install", "standard", "--no-confirm", *requested)
        installed = builder.inventory(cli, config, [p["name"] for p in plan["packages"]])
    if set(installed) != {p["name"] for p in plan["packages"]}:
        raise ValueError("Installed build package set differs from the core dependency plan")
    for package in plan["packages"]:
        if installed[package["name"]] != package["version"]:
            raise ValueError(f"Installed build input differs from core: {package['name']}")
    write(args.work / "installed-build-inputs.json", json.dumps(installed, indent=2) + "\n")
    # Read-only inventory for native package builds. All dependency provisioning
    # has already happened against the verified core snapshot above.
    write(root / "etc/shelly.conf", """[options]
DBPath = /var/lib/shelly
CacheDir = /var/cache/shelly/pkg
GPGDir = /etc/shelly.d/gnupg
LogFile = /var/log/shelly.log
Architecture = x86_64
HookDirMode = Replace
""")
    for directory in ("build/source", "build/work", "build/sources", "build/logs", "build/artifacts", "build/config/shelly"):
        (root / directory).mkdir(parents=True, exist_ok=True)
    for recipe in RECIPES:
        shutil.copytree(args.work / "source" / recipe, root / "build/source" / recipe)
    write(root / "build/config/shelly/config.json", '{"NativePackageBackend":"rlpm"}\n')
    write(root / "build/config/shelly/shellybuild.conf", build_config())
    nspawn(root, "/usr/bin/groupadd", "--gid", str(gid), "devario-build")
    nspawn(root, "/usr/bin/useradd", "--create-home", "--uid", str(uid), "--gid", str(gid),
           "--shell", "/usr/bin/bash", "devario-build")
    for path in [root / "build", *(root / "build").rglob("*")]:
        os.chown(path, uid, gid, follow_symlinks=False)
    # Test the actual container startup objects before spending time compiling.
    nspawn(root, "/usr/bin/bash", "-euc", '''
for object in crt1.o Scrt1.o crti.o crtn.o; do
  python3 /build/source/calamares/verify-isa.py "$(gcc -print-file-name="$object")"
done
''', user="devario-build")
    if args.prepare_only:
        print(f"Core build root and compiler verified: {root}", flush=True)
        return
    for recipe in RECIPES:
        print(f"Building {recipe} with the devario-core toolchain", flush=True)
        nspawn(root, "/usr/bin/shelly", "--config", "/etc/shelly.conf", "build",
               "--reviewed", "--check", "--nosign", "--no-confirm",
               "--package-destination", "/build/artifacts", f"/build/source/{recipe}/PKGBUILD",
               user="devario-build", artifacts=args.work / "artifacts")


def archive_metadata(archive, member):
    fields = {}
    for line in run("bsdtar", "-xOf", archive, member, capture_output=True, text=True).stdout.splitlines():
        key, separator, value = line.partition(" = ")
        if separator:
            fields.setdefault(key, []).append(value)
    return fields


def verify_artifacts(directory, packages):
    found = set()
    for archive in directory.glob("*.pkg.tar.zst"):
        fields = archive_metadata(archive, ".PKGINFO")
        buildinfo = archive_metadata(archive, ".BUILDINFO")
        names = fields.get("pkgname", [])
        if len(names) != 1 or names[0] not in RECIPES or names[0] in found:
            raise ValueError(f"Unexpected or duplicate installer artifact: {archive}")
        if fields.get("packager") != [PACKAGER] or buildinfo.get("packager") != [PACKAGER]:
            raise ValueError(f"Incorrect package attribution: {archive}")
        if buildinfo.get("buildtool") != ["shelly"]:
            raise ValueError(f"Expected native Shelly build metadata: {archive}")
        installed = set(buildinfo.get("installed", []))
        for package in packages:
            if package["name"] not in ("gcc", "glibc", "binutils"):
                continue
            prefix = package["name"] + "-" + package["version"] + "-"
            if not any(prefix + arch in installed for arch in ("x86_64", "any")):
                raise ValueError(f"Build metadata does not record the core {package['name']} version: {archive}")
        found.add(names[0])
    if found != set(RECIPES):
        raise ValueError("Missing installer artifacts: " + ", ".join(sorted(set(RECIPES) - found)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--keyring", type=Path, default=PROJECT / "packages/devario-keyring")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--privileged", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    for name in ("repo", "work", "keyring"):
        value = getattr(args, name).resolve()
        if value == Path("/") or re.search(r"[\s:]", str(value)):
            parser.error(f"{name} must be a non-root path without whitespace or colons")
        setattr(args, name, value)
    try:
        (provision if args.privileged else prepare)(args)
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"Core package build failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
