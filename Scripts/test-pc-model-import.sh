#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PJDV_TEST_ROOT:?Choose a fresh external SSD test directory}"
if [ -e "$PJDV_TEST_ROOT" ]; then echo "Refusing to overwrite an existing test directory" >&2; exit 1; fi
mkdir -p "$PJDV_TEST_ROOT"
bash "$PROJECT_ROOT/Scripts/build-mod-rar.sh" macos "$PJDV_TEST_ROOT/mod-rar"
xcrun swiftc -O -module-cache-path "$PJDV_TEST_ROOT/SwiftCache" \
    -I "$PROJECT_ROOT/ThirdParty/ModRAR/include" "$PJDV_TEST_ROOT/mod-rar/libpjdvarchive.a" -liconv \
    "$PROJECT_ROOT/Sources/GameContent.swift" "$PROJECT_ROOT/Sources/ModRARReader.swift" \
    "$PROJECT_ROOT/Sources/ModPackage.swift" "$PROJECT_ROOT/Sources/ModFormats.swift" \
    "$PROJECT_ROOT/Sources/ModComposition.swift" "$PROJECT_ROOT/Sources/ModInstaller.swift" "$PROJECT_ROOT/Sources/ModPlatformAnalyzer.swift" \
    "$PROJECT_ROOT/Sources/PCModelConverter.swift" "$PROJECT_ROOT/Tests/PCModelImport/main.swift" \
    -lz -o "$PJDV_TEST_ROOT/pc-model-tests"
"$PJDV_TEST_ROOT/pc-model-tests" "$PJDV_TEST_ROOT/Fixtures"
