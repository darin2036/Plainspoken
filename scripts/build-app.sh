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

# The macOS 27 SDK declares SwiftUI's @State as a macro, and the plugin that expands it
# (libSwiftUIMacros.dylib) ships only with Xcode. With just the Command Line Tools the build fails
# with "plugin for module 'SwiftUIMacros' not found", so probe-compile a @State and, if that fails,
# build against the macOS 26 SDK the Command Line Tools also install. An explicit SDKROOT wins.
if [ -z "${SDKROOT:-}" ]; then
    PROBE="$(mktemp -d)"
    trap 'rm -rf "$PROBE"' EXIT
    printf 'import SwiftUI\nstruct Probe: View { @State var x = 0; var body: some View { Text("") } }\n' > "$PROBE/Probe.swift"
    if ! swiftc -typecheck -parse-as-library -target "$(uname -m)-apple-macos26.0" "$PROBE/Probe.swift" >/dev/null 2>&1; then
        FALLBACK_SDK="$(xcode-select -p)/SDKs/MacOSX26.sdk"
        if [ -d "$FALLBACK_SDK" ]; then
            echo "note: SwiftUI macros unavailable with the default SDK; building against $FALLBACK_SDK" >&2
            export SDKROOT="$FALLBACK_SDK"
        else
            echo "warning: SwiftUI macros unavailable and no macOS 26 SDK found; install Xcode" >&2
        fi
    fi
fi

swift build -c "$CONFIG" --product Plainspoken
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Plainspoken"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Plainspoken"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

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
