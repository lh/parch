#!/bin/bash
# Build and code-sign parch with a Developer ID identity.
#
# Usage: ./scripts/build.sh
#
# Set PARCH_SIGNING_IDENTITY to override the signing identity. If unset, the
# script tries to find a Developer ID Application certificate automatically.
# If no such identity is found, the build is unsigned (but will still work
# locally, just with TCC churn on rebuilds).

set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

BINARY=".build/release/parch"

if [ -z "${PARCH_SIGNING_IDENTITY:-}" ]; then
    PARCH_SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" \
        | head -1 \
        | sed -E 's/.*"(.*)"/\1/')
fi

if [ -z "$PARCH_SIGNING_IDENTITY" ]; then
    echo "No Developer ID Application certificate found, leaving binary unsigned."
    echo "TCC permissions will not persist across rebuilds."
    exit 0
fi

echo "Signing $BINARY with: $PARCH_SIGNING_IDENTITY"
codesign --force --options runtime --sign "$PARCH_SIGNING_IDENTITY" "$BINARY"
codesign --verify --verbose=1 "$BINARY"
echo "Signed."
