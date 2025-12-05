#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COVERAGE_DIR="$SCRIPT_DIR/.coverage-data"
mkdir -p "$COVERAGE_DIR"
export COVERAGE_FILE="$COVERAGE_DIR/.coverage"

export ENABLE_INTEGRATION_TESTS=1
"$SCRIPT_DIR/run_tests.sh" --integration "$@"
