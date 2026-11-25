#!/bin/bash
set -euo pipefail
project=$(cd "$(dirname "$0")/.." && pwd)
: "${PJDV_TEST_ROOT:?Choose a fresh external-SSD test directory}"
mkdir "$PJDV_TEST_ROOT"
python3 "$project/Tests/ModArchives/build_fixtures.py" "$PJDV_TEST_ROOT/Fixtures"
"$project/Scripts/build-mod-rar.sh" macos "$PJDV_TEST_ROOT/Decoder"
xcrun swiftc -O -module-cache-path "$PJDV_TEST_ROOT/SwiftCache" \
    -I "$project/ThirdParty/ModRAR/include" "$PJDV_TEST_ROOT/Decoder/libpjdvarchive.a" \
    "$project/Sources/ModRARReader.swift" "$project/Sources/ModSwitchOverlay.swift" \
    "$project/Sources/GameContent.swift" "$project/Sources/ModPackage.swift" "$project/Sources/ModFormats.swift" \
    "$project/Sources/ModComposition.swift" "$project/Sources/ModInstaller.swift" "$project/Sources/PCModelConverter.swift" \
    "$project/Sources/ModPlatformAnalyzer.swift" "$project/Tests/ModArchives/main.swift" -liconv -lz -o "$PJDV_TEST_ROOT/mod-archives"
"$PJDV_TEST_ROOT/mod-archives" "$PJDV_TEST_ROOT/Fixtures" "$project/ThirdParty/ModRAR/fixtures" "$PJDV_TEST_ROOT/Work"
