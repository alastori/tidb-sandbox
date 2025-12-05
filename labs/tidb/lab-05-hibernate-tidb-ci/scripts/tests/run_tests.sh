#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
COVERAGE_DIR="$SCRIPT_DIR/.coverage-data"
mkdir -p "$COVERAGE_DIR"
export COVERAGE_FILE="$COVERAGE_DIR/.coverage"

usage() {
  cat <<'USAGE'
Usage: run_tests.sh [--integration] [pytest args...]

Without --integration the script runs the fast unit suite.
Use --integration to execute pytest -m integration (requires ENABLE_INTEGRATION_TESTS=1).
USAGE
}

MODE="unit"
PYTEST_ARGS=()

run_pytest() {
  local marker="$1"
  shift || true
  local cmd=(python3 -m pytest "$TEST_ROOT")
  if [[ -n "$marker" ]]; then
    cmd+=(-m "$marker")
  fi
  if (( ${#PYTEST_ARGS[@]} )); then
    cmd+=("${PYTEST_ARGS[@]}")
  fi
  "${cmd[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --integration)
      MODE="integration"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      PYTEST_ARGS+=("$1")
      shift
      ;;
  esac
done

cd "$REPO_ROOT"
TEST_ROOT="labs/tidb/lab-05-hibernate-tidb-ci/scripts/tests"

if [[ "$MODE" == "integration" ]]; then
  if [[ "${ENABLE_INTEGRATION_TESTS:-}" != "1" ]]; then
    echo "ENABLE_INTEGRATION_TESTS=1 must be set to run the integration suite." >&2
    exit 1
  fi
  run_pytest "integration"
else
  run_pytest ""
fi
