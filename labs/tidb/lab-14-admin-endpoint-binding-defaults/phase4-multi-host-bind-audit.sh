#!/usr/bin/env bash
# Phase 4 - production-style multi-container bind audit.
#
# Brings up TiDB / TiKV / PD in separate containers via docker-compose,
# then probes each component's listeners from a separate "probe" container
# on the same bridge network. Cross-container reach proves each listener
# binds to 0.0.0.0 (or another routable address), not 127.0.0.1, which is
# what production tiup cluster does by default per the topology reference.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="${SCRIPT_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="${LAB_DIR}/results"
mkdir -p "${RESULTS_DIR}"

LOG="${RESULTS_DIR}/phase4-multi-host-bind-audit-${TS}.log"

probe() {
  # Run a curl from the probe container against a peer container's URL.
  # Returns the HTTP status code (or 000 on connection failure).
  local url="$1"
  docker exec lab14-probe curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${url}" 2>/dev/null || echo "000"
}

{
  echo "=== Phase 4 - production-style multi-container bind audit ==="
  echo "Timestamp: ${TS}"
  echo "Topology: docker-compose.yml (pd-0, tikv-0, tidb-0 on bridge network lab14-net)"
  echo

  echo "--- bringing up the cluster (this can take ~60s on first run) ---"
  cd "${LAB_DIR}"
  docker compose up -d

  echo
  echo "--- waiting for TiDB to accept HTTP on tidb-0:10080 (timeout 180s) ---"
  SECONDS=0
  while ! docker exec lab14-probe curl -sf --max-time 5 http://tidb-0:10080/status > /dev/null 2>&1; do
    sleep 5
    if [ "${SECONDS}" -gt 180 ]; then
      echo "TIMEOUT after ${SECONDS}s. Recent container logs:"
      docker compose logs --tail=20
      exit 1
    fi
  done
  echo "cluster up after ${SECONDS}s"

  echo
  echo "--- version verification (from probe container, hitting tidb-0:10080/status) ---"
  docker exec lab14-probe curl -s http://tidb-0:10080/status

  echo
  echo
  echo "--- container args (proves the bind addresses each component started with) ---"
  for c in lab14-pd-0 lab14-tikv-0 lab14-tidb-0; do
    args=$(docker inspect "${c}" --format '{{join .Config.Cmd " "}}' 2>/dev/null)
    printf "%s\n  args: %s\n\n" "${c}" "${args}"
  done

  echo "--- cross-container reach probe (from lab14-probe to each component) ---"
  echo "Each 200 means the listener binds to a network-reachable address, not 127.0.0.1."
  echo
  for url in \
    "http://tidb-0:10080/info" \
    "http://tidb-0:10080/debug/pprof/" \
    "http://tidb-0:10080/config" \
    "http://tikv-0:20180/config" \
    "http://tikv-0:20180/debug/pprof/" \
    "http://pd-0:2379/pd/api/v1/config" \
    "http://pd-0:2379/pd/api/v1/members" \
    "http://pd-0:2379/debug/pprof/"; do
    code=$(probe "${url}")
    printf "  %-50s -> %s\n" "${url}" "${code}"
  done

  echo
  echo "Expected: every URL returns 200 (default 0.0.0.0 bind in production-style deploy)."
  echo "Compare to phase 2 (tiup playground), where TiKV :20180 and PD :2379"
  echo "were bound to 127.0.0.1 only and refused these probes from a non-loopback IP."

  echo
  echo "--- sample disclosure from tidb-0:10080/info (no auth required) ---"
  docker exec lab14-probe curl -s --max-time 8 http://tidb-0:10080/info || echo "(no response)"

  echo
  echo
  echo "Phase 4 cluster left running. Run ./cleanup.sh to tear down (docker compose down + tiup clean)."
} | tee "${LOG}"

echo
echo "Log written to: ${LOG}"
