#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="${PJDV_TEST_BUILD_ROOT:-/Volumes/Switch-iOS-Dev/Build}"
mkdir -p "$test_root"
output="$(mktemp -d "$test_root/ReleaseUpdates.XXXXXX")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
xcrun swiftc -module-cache-path "$output/ModuleCache" "$project_root/Sources/ReleaseUpdates.swift" "$project_root/Tests/ReleaseUpdates/main.swift" -o "$output/tests"
"$output/tests"
