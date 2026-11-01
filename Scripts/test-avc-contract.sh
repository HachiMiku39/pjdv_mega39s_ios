#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PJDV_TEST_ROOT:?Choose a fresh external SSD test directory}"
runtime="${PJDV_RUNTIME_SOURCE:-$PROJECT_ROOT/Runtime/dm}"
if [ -e "$PJDV_TEST_ROOT" ]; then echo 'Refusing to overwrite an existing test directory' >&2; exit 1; fi
mkdir -p "$PJDV_TEST_ROOT"
xcrun clang -O1 -g -fsanitize=address -fno-omit-frame-pointer \
  "-DPJDV_AVC_SOURCE=\"$runtime/gfx/pjdv_avc.c\"" \
  "$PROJECT_ROOT/Tests/test_avc_contract.c" \
  -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework CoreFoundation \
  -o "$PJDV_TEST_ROOT/avc-contract"
"$PJDV_TEST_ROOT/avc-contract"
