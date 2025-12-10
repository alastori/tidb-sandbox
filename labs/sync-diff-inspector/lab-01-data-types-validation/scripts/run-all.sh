#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"

RUN_DIAGNOSTICS="${RUN_DIAGNOSTICS:-0}"

echo "=== Running full lab workflow (start -> load MySQL -> load TiDB -> diagnostics? -> sync-diff) ==="

"${SCRIPT_DIR}/step0-start.sh"
"${SCRIPT_DIR}/step1-load-mysql.sh"
"${SCRIPT_DIR}/step2-load-tidb.sh"

if [ "${RUN_DIAGNOSTICS}" = "1" ]; then
  "${SCRIPT_DIR}/step3-capture-diagnostics.sh"
else
  echo "Skipping diagnostics (set RUN_DIAGNOSTICS=1 to enable)"
fi

"${SCRIPT_DIR}/step4-run-syncdiff.sh" all

echo "=== Done. Cleanup is manual: ${SCRIPT_DIR}/step5-cleanup.sh ==="
