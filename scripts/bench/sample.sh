#!/bin/bash
# Usage: scripts/bench/sample.sh <commit> — samples the main thread while the drag loop runs.
set -u
cd "$(dirname "$0")/../.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
mkdir -p .build/bench build
sha="$1"
rm -rf .build/bench/src && mkdir -p .build/bench/src
git archive "$sha" Sources | tar -x -C .build/bench/src
python3 scripts/bench/variant.py .build/bench/src ""
files=$(ls .build/bench/src/Sources/Mosaic/*.swift | grep -v MosaicApp.swift)
swiftc -O -g -swift-version 5 -I .build/bench/src/Sources/CSQLite .build/bench/src/Sources/MosaicCore/*.swift $files scripts/bench/main.swift -o .build/bench/sampled || exit 1
.build/bench/sampled --heavy --steps 2500 > build/sampled-$sha.log 2>&1 &
pid=$!
for i in $(seq 1 60); do grep -q STEPS-BEGIN build/sampled-$sha.log && break; sleep 0.5; done
sleep 1
sample $pid 6 -mayDie -file build/sample-$sha.txt > /dev/null 2>&1
wait $pid
cat build/sampled-$sha.log | grep -E "RESULT|PARTS"
echo "---- top of stack ($sha)"
awk '/Sort by top of stack/,0' build/sample-$sha.txt | head -40 | cut -c1-160 || true
echo "---- main thread call graph ($sha)"
python3 scripts/bench/callgraph.py build/sample-$sha.txt 60 || true
