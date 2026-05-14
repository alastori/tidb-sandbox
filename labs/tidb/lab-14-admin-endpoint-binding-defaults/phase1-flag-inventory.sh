#!/usr/bin/env bash
# Phase 1 - flag inventory.
# Reads --help output for tidb-server, tikv-server, and pd-server and prints
# the flags that control listener bindings. No cluster required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="${SCRIPT_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="${LAB_DIR}/results"
mkdir -p "${RESULTS_DIR}"

TIDB_VERSION="${TIDB_VERSION:-v8.5.6}"

LOG="${RESULTS_DIR}/phase1-flag-inventory-${TS}.log"

{
  echo "=== Phase 1 - flag inventory (TiDB ${TIDB_VERSION}) ==="
  echo "Timestamp: ${TS}"
  echo

  echo "--- tidb-server (status / advertise flags) ---"
  tiup tidb:"${TIDB_VERSION}" --help 2>&1 | grep -iE 'status|host|advertise' || true

  echo
  echo "--- tikv-server (status / advertise flags) ---"
  tiup tikv:"${TIDB_VERSION}" --help 2>&1 | grep -iE 'status-addr|advertise-status|advertise-addr|^\s+-A' || true

  echo
  echo "--- pd-server (client / peer URLs) ---"
  tiup pd:"${TIDB_VERSION}" --help 2>&1 | grep -iE 'client-urls|peer-urls|advertise' || true

  echo
  echo "Expected:"
  echo "  - tidb-server --status-host  default 0.0.0.0"
  echo "  - tikv-server --status-addr  separate from -A/--addr"
  echo "  - pd-server   --client-urls + --peer-urls (admin/debug share --client-urls)"
} | tee "${LOG}"

echo
echo "Log written to: ${LOG}"
