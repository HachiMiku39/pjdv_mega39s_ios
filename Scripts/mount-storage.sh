#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
hdiutil attach -nobrowse "$PROJECT_ROOT/Development.sparsebundle"
