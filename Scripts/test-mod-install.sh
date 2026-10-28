#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PJDV_TEST_ROOT:?Set PJDV_TEST_ROOT to a new external-SSD test directory}"
if [ -e "$PJDV_TEST_ROOT" ]; then echo "Refusing to overwrite an existing test directory" >&2; exit 1; fi
mkdir -p "$PJDV_TEST_ROOT"
python3 "$PROJECT_ROOT/Tests/ModInstall/build_fixtures.py" "$PJDV_TEST_ROOT/Fixtures"
python3 "$PROJECT_ROOT/Tests/ModPackages/build_fixtures.py" "$PJDV_TEST_ROOT/ParserFixtures"
cp "$PJDV_TEST_ROOT/ParserFixtures/zip64.zip" "$PJDV_TEST_ROOT/ParserFixtures/traversal.zip" "$PJDV_TEST_ROOT/ParserFixtures/symlink.zip" "$PJDV_TEST_ROOT/Fixtures/"
xcrun swiftc -module-cache-path "$PJDV_TEST_ROOT/SwiftCache" \
    "$PROJECT_ROOT/Sources/ModPackage.swift" "$PROJECT_ROOT/Sources/ModInstaller.swift" \
    "$PROJECT_ROOT/Tests/ModInstall/main.swift" -lz -o "$PJDV_TEST_ROOT/mod-install"
python3 - "$PJDV_TEST_ROOT/mod-install" "$PJDV_TEST_ROOT/Fixtures" <<'PY'
import resource,subprocess,sys
subprocess.run(sys.argv[1:],check=True)
print('Child peak RSS: %.1f MiB' % (resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss/1024/1024))
PY
python3 - "$PJDV_TEST_ROOT/Fixtures" <<'PY'
from pathlib import Path
import hashlib,json,sys
p=Path(sys.argv[1])
for name,digest in json.loads((p/'source-hashes.json').read_text()).items():
    assert hashlib.sha256((p/name).read_bytes()).hexdigest()==digest,name
print('PASS: original synthetic ZIP sources unchanged')
PY
