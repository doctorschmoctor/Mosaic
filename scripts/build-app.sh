#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build -c release --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
BIN_DIR=$(swift build -c release --disable-sandbox --show-bin-path --cache-path .build/cache --config-path .build/config --security-path .build/security)
APP="$PWD/build/Mosaic.app"
# Sign outside Desktop/iCloud so file-provider metadata cannot race codesign.
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/mosaic-build.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/Mosaic.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$PWD/build"
cp -X "$BIN_DIR/Mosaic" "$STAGED_APP/Contents/MacOS/Mosaic"
cp -X Resources/Info.plist "$STAGED_APP/Contents/Info.plist"
cp -X Resources/Mosaic.icns "$STAGED_APP/Contents/Resources/Mosaic.icns"
codesign --force --sign "${MOSAIC_SIGNING_IDENTITY:--}" --options runtime --entitlements Resources/Mosaic.entitlements "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
ditto -c -k --norsrc --noextattr --keepParent "$STAGED_APP" "$PWD/build/Mosaic.zip"
ditto --norsrc --noextattr "$STAGED_APP" "$APP"
# The archive is the verified distribution artifact. A Desktop file provider may
# immediately add Finder metadata to the convenience copy; install from the ZIP.
printf 'Built signed archive: %s\n' "$PWD/build/Mosaic.zip"
