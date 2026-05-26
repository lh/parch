#!/bin/bash
# Build, sign, and install parch to /usr/local/bin.
#
# Usage: ./scripts/install.sh
#
# Set PARCH_INSTALL_PREFIX to override the install location
# (default: /usr/local/bin).

set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/build.sh

BINARY=".build/release/parch"
PREFIX="${PARCH_INSTALL_PREFIX:-/usr/local/bin}"
DEST="$PREFIX/parch"

if [ ! -f "$BINARY" ]; then
    echo "Build artifact missing: $BINARY" >&2
    exit 1
fi

mkdir -p "$PREFIX"

# If a parch process is running from $DEST, replacing the binary in place
# can leave the running process in a weird state. Warn the user.
if pgrep -fx "$DEST" >/dev/null 2>&1; then
    echo "A parch process is currently running from $DEST."
    echo "Stop it first (e.g. launchctl unload ~/Library/LaunchAgents/com.parch.indexer.plist)"
    exit 1
fi

INSTALL_CMD=(install -m 0755 "$BINARY" "$DEST")
if [ -w "$PREFIX" ]; then
    "${INSTALL_CMD[@]}"
else
    echo "Installing to $DEST (sudo required)"
    sudo "${INSTALL_CMD[@]}"
fi

echo "Installed: $DEST"
"$DEST" --version 2>/dev/null || "$DEST" --help | head -1
