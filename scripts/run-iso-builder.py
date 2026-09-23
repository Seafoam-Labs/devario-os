#!/usr/bin/env python3
"""Verify and invoke the pinned Devario assembler without network access."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    for name in ("profile", "work", "output", "shelly", "config", "keyring"):
        parser.add_argument("--" + name, type=Path)
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    bundle = project / "tools/devario-iso-builder"
    lock = json.loads((bundle / "source.lock.json").read_text())
    archive = bundle / lock["archive"]
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual != lock["sha256"]:
        raise SystemExit("Devario builder archive checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="devario-iso-builder-") as temp:
        with tarfile.open(archive) as source:
            source.extractall(temp, filter="data")
        builder = Path(temp) / "devario-iso-builder/builder.py"
        if args.check:
            subprocess.run(["python3", "-m", "unittest", "discover", "-s", str(builder.parent / "tests")], check=True)
            return
        if any(getattr(args, n) is None for n in ("profile", "work", "output", "shelly", "config", "keyring")):
            parser.error("all build paths are required")
        profile = json.loads((args.profile / "profile.json").read_text())
        if set(profile) != {"schemaVersion", "architecture", "kernelId", "permissions"} or profile["schemaVersion"] != 1:
            raise SystemExit("Unsupported declarative ISO profile")
        epoch = int(os.environ.get("SOURCE_DATE_EPOCH", str(int(datetime.datetime.now().timestamp()))))
        date = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
        manifest = dict(profile, epoch=epoch, profile=str(args.profile.resolve()),
            work=str(args.work.resolve() / "image"), output=str(args.output.resolve()),
            shelly=str(args.shelly.resolve()), shellyConfig=str(args.config.resolve()), keyring=str(args.keyring.resolve()),
            name=os.environ["DEVARIO_EDITION_ISO_NAME"],
            version=os.environ.get("DEVARIO_RELEASE_VERSION") or date.strftime("%Y.%m.%d"),
            label=os.environ["DEVARIO_EDITION_ISO_LABEL_PREFIX"] + "_" + date.strftime("%Y%m"),
            publisher=os.environ["DEVARIO_EDITION_ISO_PUBLISHER"], application=os.environ["DEVARIO_EDITION_ISO_APPLICATION"],
            signing=None)
        cert, key = (os.environ.get("DEVARIO_LIVE_SIGNING_" + k) for k in ("CERT", "KEY"))
        if cert or key:
            if not cert or not key:
                raise SystemExit("Live signing requires both certificate and key")
            manifest["signing"] = dict(certificate=str(Path(cert).resolve()), key=str(Path(key).resolve()))
        path = args.work / "iso-builder-manifest.json"
        path.write_text(json.dumps(manifest, sort_keys=True) + "\n")
        subprocess.run(["python3", str(builder), "--manifest", str(path), "--validate"], check=True)
        subprocess.run(["unshare", "--mount", "--propagation", "private", "python3", str(builder), "--manifest", str(path)], check=True)


if __name__ == "__main__":
    main()
