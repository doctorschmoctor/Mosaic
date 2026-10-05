#!/bin/bash
set -u
cd "$(dirname "$0")/../.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
mkdir -p .build
files=$(ls Sources/Mosaic/*.swift | grep -v MosaicApp.swift)
swiftc -swift-version 5 -I Sources/CSQLite Sources/MosaicCore/*.swift $files scripts/focuscheck/main.swift -o .build/FocusCheck || exit 1
.build/FocusCheck
