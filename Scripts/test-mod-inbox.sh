#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
: "${PJDV_TEST_ROOT:?Choose a fresh external SSD test directory}"
if [ -e "$PJDV_TEST_ROOT" ]; then
    echo "Choose a new test directory" >&2
    exit 1
fi
mkdir -p "$PJDV_TEST_ROOT"
xcrun swiftc -module-cache-path "$PJDV_TEST_ROOT/SwiftCache" \
    "$project_root/Sources/ModInbox.swift" "$project_root/Tests/ModInbox/main.swift" -o "$PJDV_TEST_ROOT/mod-inbox"
"$PJDV_TEST_ROOT/mod-inbox" "$PJDV_TEST_ROOT/Documents"
