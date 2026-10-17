#!/bin/bash
# Regenerates App/AppIcon.icns from App/AppIcon.svg (needs only the Xcode command line tools).
set -euo pipefail

cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O scripts/render-svg.swift -o "$WORK/render-svg"
mkdir "$WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
    "$WORK/render-svg" App/AppIcon.svg "$WORK/AppIcon.iconset/icon_${size}x${size}.png" "$size"
    "$WORK/render-svg" App/AppIcon.svg "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" "$((size * 2))"
done
iconutil -c icns "$WORK/AppIcon.iconset" -o App/AppIcon.icns
echo "Wrote App/AppIcon.icns"
