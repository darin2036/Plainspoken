#!/bin/bash
# Builds build/Plainspoken.app from the SwiftPM package (no Xcode project needed).
#
#   scripts/build-app.sh            release build
#   scripts/build-app.sh debug      debug build
#   CODESIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh
#
# Always sign with the same identity: macOS ties Microphone / Input Monitoring / Accessibility
# grants to the signature, and an ad-hoc signature changes on every build (grants reset).
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Plainspoken.app"

swift build -c "$CONFIG" --product Plainspoken
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Plainspoken"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Plainspoken"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)"
fi
if [ -z "$IDENTITY" ]; then
    echo "warning: no signing identity found; using ad-hoc signature (permission grants won't persist across builds)" >&2
    IDENTITY="-"
fi

codesign --force --options runtime --entitlements App/Plainspoken.entitlements \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed: $IDENTITY)"
