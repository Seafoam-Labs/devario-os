#!/usr/bin/env bash
# Check the actual Qt Quick payload, not just the qt6-declarative package name.
set -euo pipefail
if (( $# != 1 )); then
  echo 'Usage: verify-qt-quick-package.sh QT6_DECLARATIVE_ARCHIVE' >&2
  exit 2
fi
contents="$(bsdtar -tf "$1")"
for module in Qml Quick QuickWidgets; do
  library="usr/lib/libQt6${module}.so.6"
  if ! grep -Fxq "$library" <<< "$contents" \
    || ! grep -Eq "^usr/lib/libQt6${module}\.so\.6\.[0-9]+\.[0-9]+$" <<< "$contents"; then
    echo "$(basename -- "$1") is missing $library or its versioned library. Rebuild the complete qt6-declarative package with matching qt6-shadertools." >&2
    exit 1
  fi
done
