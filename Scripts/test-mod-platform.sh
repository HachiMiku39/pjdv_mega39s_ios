#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
: "${PJDV_TEST_ROOT:?Choose a fresh external-SSD test directory}"
mkdir "$PJDV_TEST_ROOT"
python3 "$project_root/Tests/ModPlatform/build_fixtures.py" "$PJDV_TEST_ROOT/Fixtures"
bash "$project_root/Scripts/build-mod-rar.sh" macos "$PJDV_TEST_ROOT/mod-rar"
xcrun swiftc -O -module-cache-path "$PJDV_TEST_ROOT/SwiftCache" \
    -I "$project_root/ThirdParty/ModRAR/include" "$PJDV_TEST_ROOT/mod-rar/libpjdvarchive.a" -liconv \
    "$project_root/Sources/GameContent.swift" "$project_root/Sources/ModRARReader.swift" \
    "$project_root/Sources/ModPackage.swift" "$project_root/Sources/ModInstaller.swift" \
    "$project_root/Sources/ModPlatformAnalyzer.swift" "$project_root/Tests/ModPlatform/main.swift" \
    -lz -o "$PJDV_TEST_ROOT/mod-platform"
"$PJDV_TEST_ROOT/mod-platform" "$PJDV_TEST_ROOT/Fixtures/cases.json" \
    "$PJDV_TEST_ROOT/Installed" "$PJDV_TEST_ROOT/results.json"
