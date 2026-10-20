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
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Plainspoken"
cp App/Info.plist "$APP/Contents/Info.plist"

# Stamp the build so Settings can show exactly what is running: the build number is the commit
# count, and a "-dirty" suffix marks uncommitted changes. The release version stays in App/Info.plist.
PLIST="$APP/Contents/Info.plist"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git diff --quiet HEAD 2>/dev/null; then COMMIT="$COMMIT-dirty"; fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :PlainspokenCommit string $COMMIT" "$PLIST"

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
