#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PJDV_TEST_ROOT:?Choose a fresh external SSD test directory}"
if [ -e "$PJDV_TEST_ROOT" ]; then echo "Refusing to overwrite an existing test directory" >&2; exit 1; fi
mkdir -p "$PJDV_TEST_ROOT"
xcrun swiftc -O -module-cache-path "$PJDV_TEST_ROOT/SwiftCache" \
    "$PROJECT_ROOT/Sources/ModPackage.swift" "$PROJECT_ROOT/Sources/ModFormats.swift" \
    "$PROJECT_ROOT/Sources/ModComposition.swift" "$PROJECT_ROOT/Sources/ModInstaller.swift" \
    "$PROJECT_ROOT/Sources/PCModelConverter.swift" "$PROJECT_ROOT/Tests/PCModelImport/main.swift" \
    -lz -o "$PJDV_TEST_ROOT/pc-model-tests"
"$PJDV_TEST_ROOT/pc-model-tests" "$PJDV_TEST_ROOT/Fixtures"
