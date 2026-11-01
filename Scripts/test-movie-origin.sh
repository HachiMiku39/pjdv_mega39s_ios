#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PJDV_RUNTIME_SOURCE:?Set PJDV_RUNTIME_SOURCE to the dm source directory}"
: "${PJDV_TEST_ROOT:?Set PJDV_TEST_ROOT to a new external-SSD test directory}"
if [ -e "$PJDV_TEST_ROOT" ]; then echo "Refusing to overwrite an existing test directory" >&2; exit 1; fi
mkdir -p "$PJDV_TEST_ROOT"
xcrun clang -fobjc-arc -fblocks -framework Foundation -framework Metal \
    -I "$PJDV_RUNTIME_SOURCE/gfx/nvn" "$PROJECT_ROOT/Tests/MovieOrigin/main.m" \
    -o "$PJDV_TEST_ROOT/movie-origin-tests"
# Optionally pass a local authenticated shader cache file. No game data is in
# the fixture; this extra check verifies the actual generated interface too.
"$PJDV_TEST_ROOT/movie-origin-tests" "$@"
