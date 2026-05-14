#!/usr/bin/env bash
# Phase 3 - network reach probe.
# Probes TiDB status, TiKV status, and PD client from a non-loopback IP. Run
# after Phase 2 (which leaves the playground running). The probe originates
# from the same host using its LAN IP, which behaves identically to a probe
# from a different host on the same subnet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="${SCRIPT_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="${LAB_DIR}/results"
mkdir -p "${RESULTS_DIR}"

if [ "$#" -lt 1 ]; then
  cat <<EOF >&2
Usage: $0 <HOST_IP>

  HOST_IP  the host's non-loopback IP (e.g., 192.168.1.10).
           On macOS:  HOST_IP=\$(ipconfig getifaddr en0)
           On Linux:  HOST_IP=\$(hostname -I | awk '{print \$1}')

Run Phase 2 first to start the playground.
EOF
  exit 2
fi

HOST_IP="$1"
LOG="${RESULTS_DIR}/phase3-network-reach-${TS}.log"

{
  echo "=== Phase 3 - network reach probe (HOST_IP=${HOST_IP}) ==="
  echo "Timestamp: ${TS}"
  echo

  echo "--- probing admin / status routes from non-loopback IP ---"
  for url in \
    "http://${HOST_IP}:10080/info" \
    "http://${HOST_IP}:10080/debug/pprof/" \
    "http://${HOST_IP}:10080/config" \
    "http://${HOST_IP}:10080/debug/zip" \
    "http://${HOST_IP}:20180/config" \
    "http://${HOST_IP}:20180/debug/pprof/" \
    "http://${HOST_IP}:2379/pd/api/v1/config" \
    "http://${HOST_IP}:2379/debug/pprof/"; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${url}")
    printf '  %-65s -> %s\n' "${url}" "${code}"
  done

  echo
  echo "Expected:"
  echo "  TiDB :10080 routes -> 200 (no auth, reachable on the network)"
  echo "  TiKV :20180 routes -> 000 (connection refused; localhost-only)"
  echo "  PD   :2379  routes -> 000 (connection refused; localhost-only)"

  echo
  echo "--- sample /info disclosure (TiDB status, no auth) ---"
  curl -s --max-time 8 "http://${HOST_IP}:10080/info" || echo "(no response)"
} | tee "${LOG}"

echo
echo
echo "Log written to: ${LOG}"
