#!/bin/sh
# Runs the Swift tests. With full Xcode, plain `swift test` works. With only the command line tools,
# SwiftPM needs the Testing framework and its interop library added to the search paths.
set -eu
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [ -d "$CLT/Frameworks/Testing.framework" ] && ! xcodebuild -version >/dev/null 2>&1; then
  exec swift test -Xswiftc -F"$CLT/Frameworks" -Xlinker -F"$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec swift test "$@"
