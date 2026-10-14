#!/bin/bash
# Runs Mosaic as an app — its window and its menus — with fictional conversations (the demo
# workspace, and a synthetic live account), closes and opens tiles the reader's ways, and checks
# that the tiles left take their places (scripts/appcheck/AppCheck.swift). Then the same with the
# Workspace menu as it was before MenuState, to show the check catches what it guards against.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
sources=()
for file in Sources/Mosaic/*.swift; do [[ "$file" == */MosaicApp.swift ]] || sources+=("$file"); done
swiftc -O -swift-version 5 -parse-as-library -I Sources/CSQLite Sources/MosaicCore/*.swift "${sources[@]}" scripts/appcheck/AppCheck.swift -o .build/MosaicAppCheck
status=0
# The demo workspace, then a synthetic live account (polling, new messages arriving).
.build/MosaicAppCheck --demo || status=1
.build/MosaicAppCheck --isolated --live || status=1
# Where a fast scroll up a long thread spends the main thread: sampled while it scrolls.
rm -f .build/scroll-sample.txt
.build/MosaicAppCheck --isolated --live --scroll-only --sample || true
if [[ -f .build/scroll-sample.txt ]]; then
    echo "Scroll sample: the main thread's heaviest paths"
    awk '/^ *[0-9]+ Thread_[0-9]+.*Main Thread/ { main = 1; next } /^ *[0-9]+ Thread_/ { main = 0 } main' .build/scroll-sample.txt \
        | sed -E 's/  \[0x[0-9a-f,.]+\]//; s/\(in ([^)]+)\) \+ [0-9]+/(\1)/; s/ +[a-zA-Z_]+\.swift:[0-9]+//' \
        | awk '{ line = $0; sub(/^[ +!:|]*/, "", line); split(line, parts, " "); if (parts[1] + 0 >= 40) print substr($0, 1, 220) }' | head -260
fi
# The Workspace menu as it was before MenuState, reading the store: expected to fail.
for mode in "--demo" "--isolated --live"; do
    # shellcheck disable=SC2086
    if .build/MosaicAppCheck $mode --store-menus; then
        echo "App check ($mode, menus that read the store): passed too — the harness did not reproduce the stale tiles"
    else
        echo "App check ($mode, menus that read the store): as expected, the tiles were left out of place"
    fi
done
exit $status
