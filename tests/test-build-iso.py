#!/usr/bin/env python3
"""Exercise the ISO orchestrator without downloading, installing, or elevating."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "build-iso.sh"

# Subordinate build tools are replaced with observable, fallible fixtures. Real
# Bash, env, cp, flock, and sha256sum still exercise orchestration and quoting.
MOCK = r'''
import hashlib, json, os, pathlib, subprocess, sys, time
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
if name == "python3":
    name, args = pathlib.Path(args[0]).name, args[1:]
with open(os.environ["CALL_LOG"], "a") as log:
    log.write(json.dumps({"name": name, "args": args, "uid": os.geteuid(), "pid": os.getpid(), "ppid": os.getppid(),
                         "env": {k: v for k, v in os.environ.items()
                                 if k.startswith("DEVARIO_") or k in ("XDG_CONFIG_HOME", "SHELLY_ELEVATOR")}}) + "\n")
if os.environ.get("FAIL_AT") == name:
    sys.exit(17)
if name == "sudo":
    if args == ["-v"]:
        if os.environ.get("SUDO_AUTH_FAILED"):
            sys.exit(1)
        sys.exit(0)
    if args == ["-n", "-v"]:
        sys.exit(1 if os.environ.get("SUDO_REFRESH_FAILED") else 0)
    assert args[0] == "-n", "later sudo calls must not prompt"
    args = args[1:]
    assert args[0] == "--"
    # Model sudo filtering: the wrapper must pass build configuration explicitly.
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DEVARIO_", "XDG_"))}
    sys.exit(subprocess.call(args[1:], env=env))
if name == "sleep":
    time.sleep(0.02 if os.environ.get("FAST_KEEPALIVE") else 30)
if name == "validate.sh" and os.environ.get("SLOW_VALIDATION"):
    time.sleep(0.3)
if name == "validate.sh" and os.environ.get("INTERRUPT_BUILD"):
    import signal
    os.kill(os.getppid(), signal.SIGTERM)
if name == "shelly":
    config_path = pathlib.Path(os.environ["XDG_CONFIG_HOME"]) / "shelly/config.json"
    if args[:2] == ["config", "set"]:
        if os.environ.get("BACKEND_UNAVAILABLE"):
            sys.exit(19)
        config = json.loads(config_path.read_text()) if config_path.exists() else {}
        config[args[2]] = args[3]
        config_path.write_text(json.dumps(config))
    elif args[:2] == ["config", "get"]:
        print("libalpm" if os.environ.get("BACKEND_IGNORED") else json.loads(config_path.read_text())[args[2]])
    else:
        assert json.loads(config_path.read_text())["NativePackageBackend"] == "rlpm"
        # Exercise the real generated elevator, with sudo filtering XDG settings.
        code = "import json, os, pathlib; p = pathlib.Path(os.environ['XDG_CONFIG_HOME']) / 'shelly/config.json'; assert json.loads(p.read_text())['NativePackageBackend'] == 'rlpm'"
        subprocess.run([os.environ["SHELLY_ELEVATOR"], sys.executable, "-c", code], check=True)
if name == "stage-iso-repositories.py":
    if os.environ.get("DOWNLOAD_FAILED"):
        sys.exit(1)
    dest = pathlib.Path(args[args.index("--output") + 1])
    dest.mkdir()
    (dest / "verified-snapshot").touch()
    sys.exit(int(os.environ.get("STAGING_FAILED_AFTER_OUTPUT", "0")))
if name == "verify":
    assert (pathlib.Path(args[0]) / "verified-snapshot").exists()
if name == "build-packages-core.py":
    assert os.geteuid() != 0
    assert json.loads((pathlib.Path(os.environ["XDG_CONFIG_HOME"]) / "shelly/config.json").read_text())["NativePackageBackend"] == "rlpm"
    assert (pathlib.Path(args[args.index("--repo") + 1]) / "verified-snapshot").exists()
    work = pathlib.Path(args[args.index("--work") + 1])
    assert not work.exists()
    (work / "artifacts").mkdir(parents=True)
if name == "build-iso.sh":
    assert json.loads((pathlib.Path(os.environ["XDG_CONFIG_HOME"]) / "shelly/config.json").read_text())["NativePackageBackend"] == "rlpm"
    work = pathlib.Path(os.environ["DEVARIO_WORK_DIR"])
    assert not work.exists()
    work.mkdir()
    dest = pathlib.Path(os.environ["DEVARIO_OUTPUT_DIR"])
    dest.mkdir()
    if not os.environ.get("NO_IMAGE"):
        image = dest / "devario-test.iso"
        image.write_bytes(b"fixture ISO payload")
        digest = "0" * 64 if os.environ.get("BAD_CHECKSUM") else hashlib.sha256(image.read_bytes()).hexdigest()
        image.with_suffix(".iso.sha256").write_text(digest + "  " + image.name + "\n")
'''


@unittest.skipIf(os.geteuid() == 0, "The orchestrator deliberately rejects root package builds")
class BuildISOTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="devario-iso-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.os_dir = self.root / "OS checkout"
        self.scripts = self.os_dir / "scripts"
        (self.scripts / "lib").mkdir(parents=True)
        (self.os_dir / "packages/devario-keyring").mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        mock = self.bin / "mock"
        mock.write_text(f"#!{sys.executable}\n" + MOCK)
        mock.chmod(0o755)
        for name in ("python3", "sudo", "shelly", "verify", "url", "sleep"):
            (self.bin / name).symlink_to(mock)
        # These are checked for presence but run only inside the real helpers.
        for name in ("bsdtar", "repo-add", "gpg", "gpgv", "git", "patch", "xorriso",
                     "mkfs.fat", "mcopy", "mksquashfs", "openssl", "unshare",
                     "mount", "umount", "chroot", "readelf", "systemd-nspawn"):
            (self.bin / name).symlink_to("/usr/bin/true")
        for name in ("prepare-validation-env.py", "stage-iso-repositories.py", "build-packages-core.py",
                     "audit-iso-repositories.py", "audit-iso-package-paths.py"):
            (self.scripts / name).touch()
        for name in ("build-iso.sh", "stage-installer-packages.sh", "validate.sh"):
            (self.bin / name).symlink_to(mock)
            (self.scripts / name).write_text(f'#!/usr/bin/env bash\nexec {name} "$@"\n')
        (self.scripts / "with-validation-env.sh").write_text('exec "$@"\n')
        (self.scripts / "lib/repository.sh").write_text(
            'devario_verify_repository() { verify "$@"; }\n'
            'devario_validate_https_url() { url "$@"; }\n')
        self.run_dir = self.root / "run"
        self.log = self.root / "calls.jsonl"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("DEVARIO_")}
        self.config_home = self.root / "user-config"
        (self.config_home / "shelly").mkdir(parents=True)
        self.config = self.config_home / "shelly/config.json"
        self.config.write_text('{"NativePackageBackend": "libalpm", "ParallelDownloadCount": 3}\n')
        self.env.update(PATH=f"{self.bin}:{os.environ['PATH']}", CALL_LOG=str(self.log),
                        XDG_CONFIG_HOME=str(self.config_home))

    def invoke(self, *args, **env):
        return subprocess.run(
            ["bash", str(SCRIPT), "--os-dir", str(self.os_dir), "--run-dir", str(self.run_dir), *args],
            env=self.env | env, cwd=self.root, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=15)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def names(self):
        return [call["name"] for call in self.calls()]

    def assert_keepalive_stopped(self):
        pids = {call['ppid'] for call in self.calls() if call['name'] == 'sudo' and call['args'] == ['-n', '-v']}
        pids.update(call['pid'] for call in self.calls() if call['name'] == 'sleep')
        self.assertTrue(pids, 'keepalive was never exercised')
        for pid in pids:
            with self.subTest(pid=pid), self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_complete_workflow_and_explicit_sudo_environment(self):
        result = self.invoke(DEVARIO_BUILDER_PREPARE="1", DEVARIO_SIGNING_KEY="ambient-key",
                             DEVARIO_VALIDATION_OFFLINE="1")
        self.assertEqual(result.returncode, 0, result.stdout)
        phases = ["shelly", "prepare-validation-env.py", "validate.sh", "stage-iso-repositories.py",
                  "build-packages-core.py", "stage-installer-packages.sh", "audit-iso-repositories.py", "audit-iso-package-paths.py", "build-iso.sh"]
        # Backend configuration happens before the Shelly package transaction.
        operations = [call["name"] for call in self.calls() if call["name"] in phases
                      and not (call["name"] == "shelly" and call["args"][0] == "config")]
        self.assertEqual(operations, phases)
        self.assertTrue((self.run_dir / "build.log").exists())
        assembly = next(call for call in self.calls() if call["name"] == "build-iso.sh")
        self.assertEqual(assembly["env"]["DEVARIO_CORE_REPO_DIR"], str(self.run_dir / "core"))
        self.assertEqual(assembly["env"]["DEVARIO_VALIDATION_OFFLINE"], "1")
        self.assertEqual(assembly["env"]["XDG_CONFIG_HOME"], str(self.run_dir / "shelly-config"))
        self.assertEqual(json.loads(self.config.read_text())["NativePackageBackend"], "libalpm")
        build_config = json.loads((self.run_dir / "shelly-config/shelly/config.json").read_text())
        self.assertEqual(build_config, {"NativePackageBackend": "rlpm", "ParallelDownloadCount": 3})
        self.assertNotIn("build-packages.sh", self.names())
        host_install = next(call for call in self.calls() if call["name"] == "shelly" and call["args"][0] == "install")
        self.assertNotIn("base-devel", host_install["args"])
        staged = next(call for call in self.calls() if call["name"] == "stage-installer-packages.sh")
        self.assertEqual(staged["args"], [str(self.run_dir / "packages/artifacts")])
        self.assertIn("ISO ready:", result.stdout)
        self.assertEqual(sum(c['name'] == 'sudo' and c['args'] == ['-v'] for c in self.calls()), 1)
        self.assertLess(self.names().index('sudo'), self.calls().index(host_install))
        package_build = next(c for c in self.calls() if c['name'] == 'build-packages-core.py')
        self.assertEqual(package_build['env']['DEVARIO_SUDO_NONINTERACTIVE'], '1')
        self.assert_keepalive_stopped()

    def test_refreshes_during_long_work_and_stops_after_success(self):
        result = self.invoke(FAST_KEEPALIVE='1', SLOW_VALIDATION='1')
        self.assertEqual(result.returncode, 0, result.stdout)
        refreshes = [c for c in self.calls() if c['name'] == 'sudo' and c['args'] == ['-n', '-v']]
        self.assertGreater(len(refreshes), 1)
        self.assert_keepalive_stopped()

    def test_initial_authentication_failure_stops_before_host_transactions(self):
        result = self.invoke(SUDO_AUTH_FAILED='1')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertNotIn('validate.sh', self.names())
        self.assertFalse(any(c['name'] == 'shelly' and c['args'][0] == 'install' for c in self.calls()))
        self.assertFalse(any(c['name'] == 'sudo' and c['args'] == ['-n', '-v'] for c in self.calls()))

    def test_refresh_failure_stops_without_another_prompt(self):
        result = self.invoke(SUDO_REFRESH_FAILED='1')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(sum(c['name'] == 'sudo' and c['args'] == ['-v'] for c in self.calls()), 1)
        self.assertIn('Sudo credential refresh failed', result.stdout)
        self.assertNotIn('build-iso.sh', self.names())
        self.assert_keepalive_stopped()

    def test_interruption_stops_keepalive(self):
        result = self.invoke(INTERRUPT_BUILD='1')
        self.assertEqual(result.returncode, 143, result.stdout)
        self.assertNotIn('stage-iso-repositories.py', self.names())
        self.assert_keepalive_stopped()

    def test_backend_selection_failure_stops_before_package_transactions(self):
        for failure in ("BACKEND_UNAVAILABLE", "BACKEND_IGNORED"):
            with self.subTest(failure=failure):
                self.run_dir = self.root / failure
                self.log.unlink(missing_ok=True)
                result = self.invoke(**{failure: "1"})
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("build-packages-core.py", self.names())
                self.assertNotIn("build-iso.sh", self.names())
                self.assertFalse(any(call["name"] == "shelly" and call["args"][0] == "install"
                                     for call in self.calls()))
                self.assertEqual(json.loads(self.config.read_text())["NativePackageBackend"], "libalpm")

    def test_incomplete_staging_stops_before_local_compilation(self):
        result = self.invoke(STAGING_FAILED_AFTER_OUTPUT="1")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertNotIn("build-packages-core.py", self.names())
        self.assertNotIn("build-iso.sh", self.names())

    def test_download_failure_cannot_be_mistaken_for_audit_failure(self):
        result = self.invoke(DOWNLOAD_FAILED="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("build-packages-core.py", self.names())
        self.assertIn("Build failed during Stage and verify", result.stdout)

    def test_failed_validation_trust_build_or_audit_stops_assembly(self):
        for failed_step in ("validate.sh", "verify", "build-packages-core.py", "stage-installer-packages.sh",
                            "audit-iso-repositories.py", "audit-iso-package-paths.py"):
            with self.subTest(step=failed_step):
                self.run_dir = self.root / failed_step
                self.log.unlink(missing_ok=True)
                result = self.invoke(FAIL_AT=failed_step)
                self.assertEqual(result.returncode, 17, result.stdout)
                self.assertNotIn("build-iso.sh", self.names())
                self.assertIn("Build failed during", result.stdout)
                self.assert_keepalive_stopped()

    def test_existing_snapshot_and_prebuilt_packages_preserve_inputs(self):
        source, artifacts = self.root / "signed snapshot", self.root / "installer archives"
        source.mkdir()
        artifacts.mkdir()
        (source / "verified-snapshot").write_text("original")
        result = self.invoke("--skip-deps", "--repo-dir", str(source), "--installer-dir", str(artifacts))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual((source / "verified-snapshot").read_text(), "original")
        self.assertEqual(list(source.iterdir()), [source / "verified-snapshot"])
        self.assertNotIn("stage-iso-repositories.py", self.names())
        self.assertNotIn("build-packages-core.py", self.names())
        self.assertFalse(any(call["name"] == "shelly" and call["args"][0] == "install"
                             for call in self.calls()))
        staged = next(call for call in self.calls() if call["name"] == "stage-installer-packages.sh")
        self.assertEqual(staged["args"], [str(artifacts)])

    def test_bad_checksum_and_missing_image_fail(self):
        for failure in ("BAD_CHECKSUM", "NO_IMAGE"):
            with self.subTest(failure=failure):
                self.run_dir = self.root / failure
                result = self.invoke(**{failure: "1"})
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("ISO ready:", result.stdout)

    def test_dry_run_has_no_side_effects(self):
        result = self.invoke("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.run_dir.exists())
        self.assertEqual(self.calls(), [])
        self.assertIn("build-iso.sh", result.stdout)

    def test_refuse_existing_run_and_invalid_options(self):
        self.run_dir.mkdir()
        (self.run_dir / "keep").touch()
        for args in ((), ("--jobs", "0"), ("--jobs", "17"), ("--os-dir",), ("--bogus",)):
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue((self.run_dir / "keep").exists())
                self.assertEqual(self.calls(), [])

    def test_release_mode_is_not_silently_downgraded(self):
        result = self.invoke(DEVARIO_RELEASE_BUILD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
