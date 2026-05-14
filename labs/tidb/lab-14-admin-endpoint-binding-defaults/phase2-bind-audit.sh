#!/usr/bin/env bash
# Phase 2 - bind audit.
# Starts a tiup playground (single host) and uses lsof to audit which interface
# each listener binds to. Leaves the playground running for Phase 3.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="${SCRIPT_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="${LAB_DIR}/results"
mkdir -p "${RESULTS_DIR}"

TIDB_VERSION="${TIDB_VERSION:-v8.5.6}"
TAG="${TAG:-lab14-bind-audit}"

LOG="${RESULTS_DIR}/phase2-bind-audit-${TS}.log"

{
  echo "=== Phase 2 - bind audit (TiDB ${TIDB_VERSION}, tag ${TAG}) ==="
  echo "Timestamp: ${TS}"
  echo

  echo "--- starting tiup playground in background ---"
  tiup playground "${TIDB_VERSION}" --tag "${TAG}" \
    --db 1 --kv 1 --pd 1 --tiflash 0 --without-monitor \
    > "${RESULTS_DIR}/playground-${TS}.log" 2>&1 &
  PG_PID=$!
  echo "playground PID ${PG_PID}"

  echo "--- waiting for TiDB status port to bind (timeout 180s) ---"
  SECONDS=0
  while ! curl -sf http://127.0.0.1:10080/status > /dev/null 2>&1; do
    sleep 5
    if [ "${SECONDS}" -gt 180 ]; then
      echo "TIMEOUT after ${SECONDS}s. Recent playground log:"
      tail -30 "${RESULTS_DIR}/playground-${TS}.log"
      exit 1
    fi
  done
  echo "cluster up after ${SECONDS}s"
  echo

  echo "--- version verification ---"
  curl -s http://127.0.0.1:10080/status

  echo
  echo
  echo "--- bind audit (lsof on each port) ---"
  for port in 4000 10080 20180 2379; do
    bound_to=$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null \
      | grep -v '^COMMAND' \
      | awk '{print $9}' \
      | head -1)
    printf "port %-5s -> %s\n" "${port}" "${bound_to:-NOT BOUND}"
  done

  echo
  echo "Expected:"
  echo "  port 4000  -> 127.0.0.1:4000   (TiDB SQL)"
  echo "  port 10080 -> *:10080          (TiDB status - exposed to all interfaces)"
  echo "  port 20180 -> 127.0.0.1:20180  (TiKV status - localhost only)"
  echo "  port 2379  -> 127.0.0.1:2379   (PD client - localhost only)"
  echo
  echo "Playground left running for Phase 3. Run ./cleanup.sh when done."
} | tee "${LOG}"

echo
echo "Log written to: ${LOG}"
