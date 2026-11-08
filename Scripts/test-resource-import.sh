#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="${PJDV_TEST_BUILD_ROOT:-/Volumes/Switch-iOS-Dev/Build}"
mkdir -p "$test_root"
output="$(mktemp -d "$test_root/ResourceImport.XXXXXX")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
python3 "$project_root/Tests/ImportVariants/build_fixtures.py" "$output/Fixtures"
xcrun swiftc -module-cache-path "$output/ModuleCache" \
  "$project_root/Sources/XCIReader.swift" "$project_root/Sources/XCIImport.swift" \
  "$project_root/Sources/GameContent.swift" "$project_root/Sources/ResourceLibrary.swift" \
  "$project_root/Sources/ShaderAssets.swift" "$project_root/Sources/AppLanguage.swift" \
  "$project_root/Tests/ImportVariants/ContentTests.swift" -o "$output/content-tests"
"$output/content-tests" "$output/Fixtures" "$output/Output"
