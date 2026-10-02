#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
test_root="$(mktemp -d /tmp/devario-secret-material.XXXXXX)"
cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT

fail() { echo "Secret-material test failed: $*" >&2; exit 1; }
expect_rejection() {
  local label="$1"
  if "$project_dir/scripts/reject-secret-material.py" --tree "$test_root" \
      >"$test_root.stdout" 2>"$test_root.stderr"; then
    fail "$label was accepted"
  fi
  rm -f -- "$test_root"/*
}

printf '%s\n' 'ordinary public build input' > "$test_root/clean.bin"
"$project_dir/scripts/reject-secret-material.py" --tree "$test_root" >/dev/null
rm -f -- "$test_root/clean.bin"

printf '%s%s\n' '-----BEGIN ' 'PRIVATE KEY-----' > "$test_root/generic.bin"
expect_rejection 'generic PKCS#8 armor'
printf '%s%s\n' '-----BEGIN ENCRYPTED ' 'PRIVATE KEY-----' > "$test_root/encrypted.bin"
expect_rejection 'encrypted PKCS#8 armor'
printf '%s%s\n' '-----BEGIN PGP PRIVATE' ' KEY BLOCK-----' > "$test_root/openpgp.bin"
expect_rejection 'OpenPGP private armor'
printf '%s%s\n' '-----BEGIN OPENSSH ' 'PRIVATE KEY-----' > "$test_root/openssh.bin"
expect_rejection 'OpenSSH private armor'
# Minimal structurally valid v4 RSA secret-key packet: two public MPIs, four
# secret MPIs, and a two-byte simple checksum.
secret_packet='\305\033\004\000\000\000\000\001\000\001\001\000\001\001\000\000\001\001\000\001\001\000\001\001\000\001\001\000\010'
printf '%b' "$secret_packet" > "$test_root/raw-packet.bin"
expect_rejection 'raw OpenPGP secret-key packet'
printf '%s' 'unrelated-binary-prefix' > "$test_root/prefixed-packet.bin"
printf '%b' "$secret_packet" >> "$test_root/prefixed-packet.bin"
expect_rejection 'prefixed OpenPGP secret-key packet'

# A coincidental packet-tag byte in ordinary binary data is not itself proof
# of secret material.
printf '\305\001\000' > "$test_root/coincidental-tag.bin"
"$project_dir/scripts/reject-secret-material.py" --tree "$test_root" >/dev/null
rm -f -- "$test_root/coincidental-tag.bin"

# Scan a large compressed vendored source fixture whose random byte stream
# contains plausible packet-tag and length octets but no canonical OpenPGP key.
"$project_dir/scripts/reject-secret-material.py" \
  --tree "$project_dir/tools/devario-iso-builder" >/dev/null

echo 'Secret-material rejection tests passed.'
