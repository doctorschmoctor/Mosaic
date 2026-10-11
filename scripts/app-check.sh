#!/bin/bash
# Runs Mosaic as an app — its window and its menus — with the fictional demo workspace, closes
# and opens tiles the reader's ways, and checks that the tiles left take their places
# (scripts/appcheck/AppCheck.swift). Then the same with a menu that reads the store's tiles
# directly, to show the check catches what it guards against (that run is expected to fail).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
sources=()
for file in Sources/Mosaic/*.swift; do [[ "$file" == */MosaicApp.swift ]] || sources+=("$file"); done
swiftc -swift-version 5 -parse-as-library -I Sources/CSQLite Sources/MosaicCore/*.swift "${sources[@]}" scripts/appcheck/AppCheck.swift -o .build/MosaicAppCheck
.build/MosaicAppCheck --demo
if .build/MosaicAppCheck --demo --store-menus; then
    echo "App check: menus that read the store passed too (the harness did not reproduce the stale tiles)"
else
    echo "App check: as expected, menus that read the store left the tiles out of place"
fi
