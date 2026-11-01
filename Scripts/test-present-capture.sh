#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PJDV_RUNTIME_SOURCE:?Set PJDV_RUNTIME_SOURCE to the dm source directory}"
: "${PJDV_TEST_ROOT:?Set PJDV_TEST_ROOT to a new external-SSD test directory}"
if [ -e "$PJDV_TEST_ROOT" ]; then echo "Refusing to overwrite an existing test directory" >&2; exit 1; fi
mkdir -p "$PJDV_TEST_ROOT"
xcrun clang -fobjc-arc -fblocks -framework Foundation -framework Metal \
    -I "$PJDV_RUNTIME_SOURCE/gfx/nvn" "$PROJECT_ROOT/Tests/PresentCapture/main.m" \
    -o "$PJDV_TEST_ROOT/present-capture-tests"
for mode in on off legacy; do "$PJDV_TEST_ROOT/present-capture-tests" "$PJDV_TEST_ROOT/$mode" "$mode"; done
