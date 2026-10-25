#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD_HOST="${PJDV_MOD_HOST:-$PROJECT_ROOT/Runtime/dm/host}"
: "${PJDV_TEST_ROOT:?Set PJDV_TEST_ROOT to a new test-output directory on your external SSD}"
if [ -e "$PJDV_TEST_ROOT" ]; then
    echo "Refusing to overwrite an existing test directory" >&2
    exit 1
fi
mkdir -p "$PJDV_TEST_ROOT"
clang -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    -fsanitize=address,undefined -g -I "$MOD_HOST" \
    -x c "$MOD_HOST/pjdv_mod_interface.inc" "$PROJECT_ROOT/Tests/ModInterface/main.c" \
    -o "$PJDV_TEST_ROOT/mod-interface"
"$PJDV_TEST_ROOT/mod-interface"
