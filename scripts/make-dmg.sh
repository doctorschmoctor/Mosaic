#!/bin/bash
# Packages the signed app archive (build/Mosaic.zip, from build-app.sh) as a disk image for a
# release: open it, drag Mosaic to the Applications folder beside it. The image is checked by
# mounting it and reading the app's signature back before it is accepted.
# Usage: scripts/make-dmg.sh [output.dmg]   (default: build/Mosaic-<version>.dmg)
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHIVE="$PWD/build/Mosaic.zip"
[ -f "$ARCHIVE" ] || { echo "No build/Mosaic.zip: run scripts/build-app.sh first" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
OUTPUT="${1:-$PWD/build/Mosaic-$VERSION.dmg}"

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/mosaic-dmg.XXXXXX")
MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/mosaic-mount.XXXXXX")
cleanup() { hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rm -rf "$STAGING" "$MOUNT"; }
trap cleanup EXIT

# The app exactly as archived (ditto keeps the signature intact), and a link to /Applications.
ditto -x -k "$ARCHIVE" "$STAGING"
ln -s /Applications "$STAGING/Applications"
rm -f "$OUTPUT"
hdiutil create -volname "Mosaic $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov -quiet "$OUTPUT"

# Read it back: the image mounts, the app is there, and its signature still verifies.
hdiutil attach "$OUTPUT" -mountpoint "$MOUNT" -nobrowse -readonly -quiet
test -d "$MOUNT/Mosaic.app"
test -L "$MOUNT/Applications"
codesign --verify --deep --strict "$MOUNT/Mosaic.app"
MOUNTED_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$MOUNT/Mosaic.app/Contents/Info.plist")
[ "$MOUNTED_VERSION" = "$VERSION" ] || { echo "The image holds version $MOUNTED_VERSION, expected $VERSION" >&2; exit 1; }
hdiutil detach "$MOUNT" -quiet
printf 'Built disk image: %s\n' "$OUTPUT"
