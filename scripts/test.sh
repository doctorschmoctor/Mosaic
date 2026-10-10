#!/bin/bash
# Runs the whole suite. Tests are fixture runs (see MosaicRuntime): they use fictional contacts,
# a temporary folder for outgoing files and synthetic Messages databases, and cannot send, so the
# result is the same whether Contacts is allowed, denied or unavailable on this Mac.
#
# A test that stops making progress is reported by name and the run stops, instead of hanging:
# MOSAIC_TEST_STALL_SECONDS (default 300) is how long the run may go without any output.
# Extra arguments go to `swift test` (for example: --filter MosaicCoreTests).
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
STALL_SECONDS="${MOSAIC_TEST_STALL_SECONDS:-300}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mosaic-test.XXXXXX")
LOG="$WORK/output.log"
PIDFILE="$WORK/pid"
: > "$LOG"

stop_tests() {
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$pid" ]; then
        pkill -TERM -P "$pid" 2>/dev/null || true
        kill -TERM "$pid" 2>/dev/null || true
    fi
    pkill -TERM -f "MosaicPackageTests.xctest" 2>/dev/null || true
}
trap 'rm -rf "$WORK"' EXIT
trap 'stop_tests; exit 130' INT TERM

( swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security ${@+"$@"} &
  echo $! > "$PIDFILE"
  wait $! ) 2>&1 | tee "$LOG" &
RUN=$!

last_size=-1
quiet=0
while kill -0 "$RUN" 2>/dev/null; do
    sleep 5
    size=$(wc -c < "$LOG" | tr -d ' ')
    if [ "$size" = "$last_size" ]; then quiet=$((quiet + 5)); else quiet=0; last_size=$size; fi
    if [ "$quiet" -ge "$STALL_SECONDS" ]; then
        started=$(grep -E "Test Case '.*' started" "$LOG" | tail -n 1 || true)
        echo ""
        echo "error: no test output for ${STALL_SECONDS}s; stopping the run."
        if [ -n "$started" ]; then
            echo "error: stalled in ${started% started.}"
        else
            echo "error: stalled before any test started (building or launching the test bundle)."
        fi
        stop_tests
        wait "$RUN" 2>/dev/null || true
        exit 1
    fi
done

status=0
wait "$RUN" || status=$?
echo ""
echo "Full suite: $(grep -E "Test Suite 'All tests' (passed|failed)" "$LOG" | tail -n 1 || echo "no summary")"
grep -E "Executed [0-9]+ tests?, with" "$LOG" | tail -n 1 || true
exit "$status"
