#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
: "${PJDV_RUNTIME_SOURCE:?Set PJDV_RUNTIME_SOURCE to the dm source directory}"
: "${PJDV_TEST_ROOT:?Set PJDV_TEST_ROOT to an external test directory}"
mkdir -p "$PJDV_TEST_ROOT"
test_binary="$PJDV_TEST_ROOT/test-transparency-origin"
xcrun clang -Wall -fobjc-arc -fblocks -framework Foundation -framework Metal \
    -I "$PJDV_RUNTIME_SOURCE/gfx/nvn" "$project/Tests/TransparencyOrigin/main.m" -o "$test_binary"
"$test_binary"
if [[ $# -gt 0 ]]; then
    # Optional original ae69a82033f2da08_b.metallib from a local source cache.
    "$test_binary" "$1"
fi
