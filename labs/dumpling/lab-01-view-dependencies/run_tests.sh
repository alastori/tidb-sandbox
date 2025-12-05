#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "ENV file not found at $ENV_FILE"
  echo "Copy .env.example to .env and adjust as needed."
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

TS="${TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/results}"
mkdir -p "$RESULTS_DIR"

export ENV_FILE TS RESULTS_DIR

echo "Using TS=$TS"

run_step() {
  local step_script="$1"
  local label="$2"
  echo
  echo ">>> Running $label"
  bash "$SCRIPT_DIR/$step_script" | tee "$RESULTS_DIR/${label}-$TS.log"
}

run_step step0-preflight.sh step0-preflight
run_step step1-start-mysql.sh step1-start-mysql
run_step step2-validate-upstream.sh step2-validate-upstream
run_step step3-mysqldump.sh step3-mysqldump
run_step step4-mydumper.sh step4-mydumper
run_step step5-dumpling.sh step5-dumpling
run_step step6-cleanup.sh step6-cleanup
