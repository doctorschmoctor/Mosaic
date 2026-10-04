#!/bin/bash
# Usage: scripts/bench/run.sh <commit>... — builds each commit's sources with the drag benchmark and runs it.
set -uo pipefail
cd "$(dirname "$0")/../.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
mkdir -p .build/bench
cp scripts/bench/main.swift .build/bench/main.swift
for sha in "$@"; do
  rm -rf .build/bench/src && mkdir -p .build/bench/src
  git archive "$sha" Sources | tar -x -C .build/bench/src
  files=$(ls .build/bench/src/Sources/Mosaic/*.swift | grep -v MosaicApp.swift)
  if ! swiftc -O -swift-version 5 -I .build/bench/src/Sources/CSQLite .build/bench/src/Sources/MosaicCore/*.swift $files .build/bench/main.swift -o .build/bench/bench-$sha 2> .build/bench/err-$sha.txt; then
    echo "BUILD FAILED $sha"; grep error: .build/bench/err-$sha.txt | head -5; continue
  fi
  for mode in "" "--heavy"; do
    for run in 1 2 3; do
      echo -n "$sha run$run "; .build/bench/bench-$sha $mode | grep RESULT
    done
  done
done
