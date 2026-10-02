#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Collect the diagnostics provided by cachyos-bugreport.sh for Devario.
set -euo pipefail
umask 077

desktop=0
upload_mode=ask
work_dir=

usage() {
    cat <<'EOF'
Usage: devario-report.sh [--no-upload | --upload] [--desktop]

Collect hardware, scheduler, kernel and boot logs, and installed packages.
Save a redacted devario-report.log in the current directory, then offer to
publish it to https://paste.c-net.org/. LOG_FILENAME overrides the file path.

  --no-upload  Only save the report locally
  --upload     Publish without the interactive upload prompt
  --desktop    Save under ~/.local/state/devario/reports and keep the window open
  -h, --help   Show this help

Administrator authentication is requested for restricted system logs.
Redaction is best effort; review the saved report before publishing it.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --desktop) desktop=1 ;;
        --no-upload) upload_mode=no ;;
        --upload) upload_mode=yes ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

cleanup() {
    local status=$?
    [[ -z "$work_dir" ]] || rm -rf -- "$work_dir"
    if (( desktop )) && [[ -t 0 ]]; then
        read -r -p 'Press Enter to close this window. ' _ || true
    fi
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if (( desktop )); then
    report_dir="${XDG_STATE_HOME:-$HOME/.local/state}/devario/reports"
    mkdir -p -- "$report_dir"
    cd -- "$report_dir"
fi
log_filename="${LOG_FILENAME:-devario-report.log}"
if [[ -d "$log_filename" || -d "$log_filename.old" ]]; then
    printf 'Report path or backup is a directory: %s\n' "$log_filename" >&2
    exit 1
fi
# Create private scratch files beside the destination for an atomic final move.
work_dir=$(mktemp -d -- "$(dirname -- "$log_filename")/.devario-report.XXXXXX")

privileged=()
if (( EUID != 0 )); then
    printf 'Authenticating to read kernel and system logs...\n'
    sudo -v
    privileged=(sudo --)
fi

section() {
    local title=$1
    shift
    printf '\n____________________________________________\n%s\n\n' "$title"
    if "$@"; then
        return 0
    else
        printf '\n[Unavailable or incomplete: command exited with status %s]\n' "$?"
    fi
}

printf 'Collecting Devario report...\n'
{
    printf 'Devario system report\nDate: '
    date --iso-8601=seconds
    section 'System' uname -a
    section 'OS release' cat /etc/os-release
    section 'Kernel command line' cat /proc/cmdline
    section 'Hardware information' inxi -Farz
    section 'sched-ext' grep -R '' /sys/kernel/sched_ext/
    section 'Kernel scheduler messages' bash -o pipefail -c \
        '"$@" journalctl --no-pager --output cat -b -k | grep -i scheduler' _ "${privileged[@]}"
    section 'dmesg' "${privileged[@]}" dmesg
    section 'Journal of current boot (warnings and errors)' \
        "${privileged[@]}" journalctl --no-pager -b -p 4..1
    section 'Journal of previous boot (warnings and errors)' \
        "${privileged[@]}" journalctl --no-pager -b -1 -p 4..1
    section 'Installed packages (Shelly)' shelly list standard --show-hidden --json
} >"$work_dir/raw" 2>&1

printf 'Redacting personal information...\n'
python3 - "$work_dir/raw" "$work_dir/redacted" <<'PY'
import ipaddress
import os
import pwd
import re
import socket
import sys

with open(sys.argv[1], encoding="utf-8", errors="replace") as source:
    text = source.read()

def literal(value, replacement):
    global text
    if value:
        text = re.sub(r"(?<![\w.-])" + re.escape(value) + r"(?![\w.-])",
                      lambda _: replacement, text)

# Include local login users because journal entries can mention other sessions.
for account in pwd.getpwall():
    if account.pw_name != "root" and (1000 <= account.pw_uid < 65534
                                     or account.pw_name == os.environ.get("SUDO_USER")):
        if account.pw_dir not in ("", "/", "/nonexistent"):
            literal(account.pw_dir, "<home-dir-redacted>")
        literal(account.pw_name, "<username-redacted>")
literal(socket.gethostname(), "<hostname-redacted>")
text = re.sub(r"[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}", "<email-address-redacted>", text)
text = re.sub(r"(?i)\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b",
              "<mac-address-redacted>", text)

def redact_ip(match):
    value = match.group()
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return value
    return f"<ipv{address.version}-redacted>"

# IPv6 first, including compressed and IPv4-mapped addresses. ipaddress rejects
# timestamps and PCI addresses, keeping those useful diagnostics intact.
text = re.sub(r"(?<![\w:])(?:[0-9A-Fa-f]*:){2,}[0-9A-Fa-f:.]*(?![\w:])",
              redact_ip, text)
text = re.sub(r"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b", redact_ip, text)
with open(sys.argv[2], "w", encoding="utf-8") as target:
    target.write(text)
PY

# Preserve the previous report and never follow a destination symlink.
if [[ -e "$log_filename" || -L "$log_filename" ]]; then
    mv -fT -- "$log_filename" "$log_filename.old"
fi
mv -fT -- "$work_dir/redacted" "$log_filename"
if (( EUID == 0 )) && [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    chown -- "$SUDO_USER:" "$log_filename"
fi
printf 'Report saved to %s\n' "$(realpath -- "$log_filename")"

if [[ "$upload_mode" == ask ]]; then
    printf 'Review this file before sharing; redaction may not remove every private detail.\n'
    if read -r -p 'Publish this report publicly to https://paste.c-net.org/? [y/N] ' answer \
        && [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]]; then
        upload_mode=yes
    fi
fi
if [[ "$upload_mode" != yes ]]; then
    printf 'Report kept locally.\n'
    exit 0
fi

printf 'Uploading report...\n'
if ! paste_url=$(curl --disable --fail --silent --show-error \
    --proto '=https' --connect-timeout 15 --max-time 120 \
    --header 'Content-Type: text/plain; charset=utf-8' \
    --data-binary @- https://paste.c-net.org/ <"$log_filename"); then
    printf 'Upload failed. Your local report is still available at %s\n' "$log_filename" >&2
    exit 1
fi
paste_url=${paste_url%$'\r'}
if [[ ! "$paste_url" =~ ^https://paste\.c-net\.org/[A-Za-z0-9_-]+$ ]]; then
    printf 'Paste service returned an invalid URL. Local report: %s\n' "$log_filename" >&2
    exit 1
fi
printf 'Public report: %s\n' "$paste_url"
