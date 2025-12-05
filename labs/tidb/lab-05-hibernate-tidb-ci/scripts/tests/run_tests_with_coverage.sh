#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
COVERAGE_DIR="$SCRIPT_DIR/.coverage-data"
mkdir -p "$COVERAGE_DIR"
export COVERAGE_FILE="$COVERAGE_DIR/.coverage"

cd "$REPO_ROOT"
python3 -m pytest labs/tidb/lab-05-hibernate-tidb-ci/scripts/tests \
  --cov=labs/tidb/lab-05-hibernate-tidb-ci/scripts \
  --cov-report=term-missing \
  "$@"
