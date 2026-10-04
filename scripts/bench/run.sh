#!/bin/bash
# Usage: scripts/bench/run.sh <commit> <variant>... — variants are +-joined patch names ("" = counters only).
set -uo pipefail
cd "$(dirname "$0")/../.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
mkdir -p .build/bench build
cp scripts/bench/main.swift .build/bench/main.swift
sha="$1"; shift
for variant in "$@"; do
  tag=${variant:-base}
  rm -rf .build/bench/src && mkdir -p .build/bench/src
  git archive "$sha" Sources | tar -x -C .build/bench/src
  python3 scripts/bench/variant.py .build/bench/src "$variant" || { echo "PATCH FAILED $tag"; continue; }
  files=$(ls .build/bench/src/Sources/Mosaic/*.swift | grep -v MosaicApp.swift)
  if ! swiftc -O -swift-version 5 -I .build/bench/src/Sources/CSQLite .build/bench/src/Sources/MosaicCore/*.swift $files .build/bench/main.swift -o .build/bench/bench-$tag 2> .build/bench/err-$tag.txt; then
    echo "BUILD FAILED $tag"; grep error: .build/bench/err-$tag.txt | head -5; continue
  fi
  for run in 1 2 3; do
    echo "== $tag run$run"; .build/bench/bench-$tag --heavy --capture build/bench-$tag.png | grep -E "RESULT|COUNTS|IDLE|PARTS|DRAG"
  done
done
