#!/usr/bin/env python3
"""Fail closed when a source or image tree contains private-key material."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import subprocess
import sys


PRIVATE_HEADERS = (
    ("-----BEGIN " + "PRIVATE KEY-----").encode(),
    ("-----BEGIN " + "ENCRYPTED PRIVATE KEY-----").encode(),
    ("-----BEGIN " + "RSA PRIVATE KEY-----").encode(),
    ("-----BEGIN " + "DSA PRIVATE KEY-----").encode(),
    ("-----BEGIN " + "EC PRIVATE KEY-----").encode(),
    ("-----BEGIN " + "OPENSSH PRIVATE KEY-----").encode(),
    ("-----BEGIN PGP PRIVATE" + " KEY BLOCK-----").encode(),
)


def packet_length(
    data: bytes, offset: int, new_format: bool, header: int
) -> tuple[int, int] | None:
    cursor = offset + 1
    if cursor >= len(data):
        return None
    first = data[cursor]
    if new_format:
        if first < 192:
            return first, cursor + 1
        if first < 224:
            if cursor + 1 >= len(data):
                return None
            return ((first - 192) << 8) + data[cursor + 1] + 192, cursor + 2
        if first == 255:
            if cursor + 4 >= len(data):
                return None
            return int.from_bytes(data[cursor + 1 : cursor + 5], "big"), cursor + 5
        # Partial-body lengths are valid OpenPGP, but public/secret key packets
        # are not emitted with partial lengths. Stop rather than guess offsets.
        return None
    length_type = header & 0x03
    if length_type == 0:
        return first, cursor + 1
    if length_type == 1:
        if cursor + 1 >= len(data):
            return None
        return int.from_bytes(data[cursor : cursor + 2], "big"), cursor + 2
    if length_type == 2:
        if cursor + 3 >= len(data):
            return None
        return int.from_bytes(data[cursor : cursor + 4], "big"), cursor + 4
    return None


def mpi_end(body: bytes, cursor: int) -> int | None:
    if cursor + 2 > len(body):
        return None
    bits = int.from_bytes(body[cursor : cursor + 2], "big")
    size = (bits + 7) // 8
    end = cursor + 2 + size
    if bits == 0 or end > len(body):
        return None
    # RFC 4880 MPIs are minimally encoded: the declared bit count must equal
    # the actual most-significant set bit. Random compressed bytes frequently
    # happen to describe in-bounds lengths, but not canonical MPI values.
    first = body[cursor + 2]
    if first == 0 or (size - 1) * 8 + first.bit_length() != bits:
        return None
    return end


def looks_like_secret_key_body(body: bytes) -> bool:
    # Validate enough of RFC 4880's secret-key grammar to avoid treating a
    # random 0xc5/0xc7 byte in an ELF or compressed file as key material.
    # Version 4 keys cover the production formats emitted by current GnuPG.
    if len(body) < 16 or body[0] != 4:
        return False
    algorithm = body[5]
    public_mpis = {1: 2, 2: 2, 3: 2, 16: 3, 17: 4, 20: 3}.get(algorithm)
    if public_mpis is None:
        # ECC public material has an OID followed by an encoded point MPI. The
        # ECDH algorithm additionally carries a length-prefixed KDF field.
        if algorithm not in (18, 19, 22):
            return False
        cursor = 6
        if cursor >= len(body) or not 1 <= body[cursor] <= 64:
            return False
        cursor += 1 + body[cursor]
        cursor = mpi_end(body, cursor) or -1
        if cursor < 0:
            return False
        if algorithm == 18:
            if cursor >= len(body) or cursor + 1 + body[cursor] > len(body):
                return False
            cursor += 1 + body[cursor]
        secret_mpis = 1
    else:
        cursor = 6
        for _ in range(public_mpis):
            cursor = mpi_end(body, cursor) or -1
            if cursor < 0:
                return False
        secret_mpis = 4 if algorithm in (1, 2, 3) else 1
    if cursor >= len(body):
        return False
    usage = body[cursor]
    cursor += 1
    if usage == 0:
        for _ in range(secret_mpis):
            cursor = mpi_end(body, cursor) or -1
            if cursor < 0:
                return False
        return cursor + 2 == len(body)
    if usage in (254, 255):
        # Symmetric algorithm + S2K specifier + salt/parameters + ciphertext.
        return (
            cursor + 4 < len(body)
            and 1 <= body[cursor] <= 13
            and body[cursor + 1] in (0, 1, 3, 101)
            and len(body) - cursor >= 12
        )
    # Legacy convention: the usage octet itself is the symmetric algorithm.
    return 1 <= usage <= 13 and len(body) - cursor >= 10


def contains_secret_openpgp_packet(data: bytes) -> bool:
    # A key packet does not have to start at byte zero: files seen in incident
    # response often have a short application header or other binary prefix.
    # Test every plausible packet boundary and fail closed on a complete secret
    # key/subkey packet, while still accepting arbitrary non-packet prefixes.
    for offset in range(len(data)):
        header = data[offset]
        if not header & 0x80:
            continue
        new_format = bool(header & 0x40)
        tag = header & 0x3F if new_format else (header >> 2) & 0x0F
        parsed = packet_length(data, offset, new_format, header)
        if parsed is None:
            continue
        length, body_offset = parsed
        if length < 0 or body_offset + length > len(data):
            continue
        if tag in (5, 7) and looks_like_secret_key_body(
            data[body_offset : body_offset + length]
        ):  # Secret-Key and Secret-Subkey.
            return True
    return False


def git_tracked(root: Path) -> list[Path]:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        check=True,
        stdout=subprocess.PIPE,
    )
    return [root / os.fsdecode(item) for item in result.stdout.split(b"\0") if item]


def full_tree(root: Path) -> list[Path]:
    paths: list[Path] = []
    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [name for name in dirnames if name != ".git"]
        paths.extend(Path(directory) / name for name in filenames)
    return paths


def main() -> int:
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--git-tracked", metavar="ROOT", type=Path)
    source.add_argument("--tree", metavar="ROOT", type=Path)
    args = parser.parse_args()
    root = (args.git_tracked or args.tree).resolve(strict=True)
    paths = git_tracked(root) if args.git_tracked else full_tree(root)
    failures: list[str] = []

    for path in paths:
        try:
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                continue
            if not stat.S_ISREG(mode):
                failures.append(f"special filesystem entry: {path.relative_to(root)}")
                continue
            data = path.read_bytes()
        except OSError as error:
            failures.append(f"unreadable file {path.relative_to(root)}: {error}")
            continue
        if any(header in data for header in PRIVATE_HEADERS):
            failures.append(f"private-key armor: {path.relative_to(root)}")
        elif contains_secret_openpgp_packet(data):
            failures.append(f"OpenPGP secret-key packet: {path.relative_to(root)}")

    if failures:
        for failure in failures:
            print(f"Secret-material rejection: {failure}", file=sys.stderr)
        return 1
    print(f"Secret-material scan passed for {len(paths)} files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
