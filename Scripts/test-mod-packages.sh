#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PJDV_TEST_ROOT:?Set PJDV_TEST_ROOT to a new external-SSD test directory}"
if [ -e "$PJDV_TEST_ROOT" ]; then echo "Refusing to overwrite an existing test directory" >&2; exit 1; fi
mkdir -p "$PJDV_TEST_ROOT"
python3 "$PROJECT_ROOT/Tests/ModPackages/build_fixtures.py" "$PJDV_TEST_ROOT/Fixtures"
xcrun swiftc -sanitize=address -module-cache-path "$PJDV_TEST_ROOT/SwiftCache" \
    "$PROJECT_ROOT/Sources/ModPackage.swift" "$PROJECT_ROOT/Tests/ModPackages/main.swift" \
    -o "$PJDV_TEST_ROOT/mod-packages"
"$PJDV_TEST_ROOT/mod-packages" "$PJDV_TEST_ROOT/Fixtures"
python3 - "$PJDV_TEST_ROOT/Fixtures" <<'PY'
from pathlib import Path
import hashlib,json,sys
p=Path(sys.argv[1]);expected=json.loads((p/'source-hashes.json').read_text())
for name,digest in expected.items():assert hashlib.sha256((p/name).read_bytes()).hexdigest()==digest,name
print('PASS: original synthetic source files unchanged')
PY
