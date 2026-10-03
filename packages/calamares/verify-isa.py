#!/usr/bin/env python3
"""Reject ELF files declaring an ISA requirement or use above x86-64-v3.

ISA notes alone cannot establish instruction compatibility. The recipe also
pins compiler flags and checks the toolchain's startup objects before building.
"""
import argparse
from pathlib import Path
import re
import subprocess


def verify(path):
    candidates = sorted(path.rglob('*')) if path.is_dir() else [path]
    checked = 0
    for candidate in candidates:
        if candidate.is_symlink() or not candidate.is_file():
            continue
        with candidate.open('rb') as source:
            if source.read(4) != b'\x7fELF':
                continue
        notes = subprocess.check_output(['readelf', '-n', str(candidate)], text=True)
        for line in notes.splitlines():
            if 'x86 ISA' in line and any(int(level) > 3 for level in re.findall(r'x86-64-v(\d+)', line)):
                raise ValueError(f'{candidate} exceeds x86-64-v3: {line.strip()}; rebuild with a v3-compatible toolchain')
        checked += 1
    if not checked:
        raise ValueError(f'No ELF files found in {path}')
    return checked


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', type=Path)
    args = parser.parse_args()
    try:
        count = verify(args.path)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Calamares ISA check: {error}\n')
    print(f'Calamares ISA check: {count} ELF files have no ISA notes above x86-64-v3')
