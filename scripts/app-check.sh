#!/bin/bash
# A/B, temporary: the details benchmark with the details as they were (scripts/appcheck/old)
# and as they are, alternately, on one machine.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
new=(); old=()
for file in Sources/Mosaic/*.swift; do
    [[ "$file" == */MosaicApp.swift ]] && continue
    new+=("$file")
    base=$(basename "$file")
    if [[ -f "scripts/appcheck/old/$base" ]]; then old+=("scripts/appcheck/old/$base"); else old+=("$file"); fi
done
swiftc -O -swift-version 5 -parse-as-library -I Sources/CSQLite Sources/MosaicCore/*.swift "${new[@]}" scripts/appcheck/AppCheck.swift -o .build/MosaicAppCheck
swiftc -O -swift-version 5 -parse-as-library -I Sources/CSQLite Sources/MosaicCore/*.swift "${old[@]}" scripts/appcheck/AppCheck.swift -o .build/MosaicAppCheckOld
for round in 1 2 3; do
    for build in Old New; do
        bin=.build/MosaicAppCheck; [[ $build == Old ]] && bin=.build/MosaicAppCheckOld
        echo "=== $build, round $round"
        $bin --isolated --live --details || true
    done
done
exit 0
