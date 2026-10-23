#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="${PJDV_TEST_ROOT:?Set PJDV_TEST_ROOT to a new directory on your APFS test disk}"
if [ -e "$TEST_ROOT" ]; then
  echo 'Refusing to reuse a test directory; choose a new PJDV_TEST_ROOT.' >&2
  exit 2
fi
mkdir -p "$TEST_ROOT"
cd "$PROJECT_ROOT"
python3 Tests/ImportVariants/build_fixtures.py "$TEST_ROOT/Fixtures"
xcrun --sdk macosx swiftc -O -module-cache-path "$TEST_ROOT/ModuleCache" \
  Sources/XCIReader.swift Sources/GameContent.swift Sources/XCIImport.swift \
  Sources/ShaderAssets.swift Sources/ResourceLibrary.swift Sources/AppLanguage.swift \
  Tests/ImportVariants/ContentTests.swift -o "$TEST_ROOT/content-tests"
"$TEST_ROOT/content-tests" "$TEST_ROOT/Fixtures" "$TEST_ROOT/Output"
xcrun --sdk macosx swiftc -O -module-cache-path "$TEST_ROOT/ModuleCache" \
  Sources/XCIReader.swift Tests/ImportVariants/StreamingMemoryTests.swift \
  -o "$TEST_ROOT/stream-memory-tests"
"$TEST_ROOT/stream-memory-tests" "$TEST_ROOT/StreamMemory"
echo 'Only bounded synthetic XCI / dummy keys and a temporary 1 MiB stream file were generated. No game content was read.'
