#!/usr/bin/env bash
# Phase 3 - production-style multi-container deploy. Faithful proxy for
# tiup cluster (which sets listen_host: 0.0.0.0 globally). PD / TiKV / TiDB
# each in its own container. Two sequential passes:
#
#   3A. TLS off: ./docker-compose.yml (no certs, plaintext inter-component)
#   3B. TLS on:  ./docker-compose-tls.yml (mounts ./certs/ + ./tls-overlays/
#       and starts each component with --config <overlay>)
#
# For each pass, filters each container's startup log through LOG_SUBSTR
# (default: case-insensitive '(tls|ssl)'). With the default pattern: pass 3A
# logs no TLS handshake lines, pass 3B logs TLS-related lines for each
# component as cert paths load.
#
# TiFlash is intentionally absent from phase 3 (both passes). Its bring-up
# requires substantial extra config (tiflash.toml + tiflash_proxy.toml +
# RaftStore wiring) disproportionate to phase 3's demonstration value.
# TiFlash with TLS off and TLS on is covered by phase 2 via tiup playground
# (the --tls flag auto-wires all 4 components).
#
# Forward-looking: if a future TiDB release adds a startup warning about
# missing inter-component TLS, set LOG_SUBSTR to that warning text and re-run.
# Pass 3A should print the warning; pass 3B should stay silent (TLS configured).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="${SCRIPT_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="${LAB_DIR}/results"
mkdir -p "${RESULTS_DIR}"

LOG_SUBSTR="${LOG_SUBSTR:-(tls|ssl)}"

LOG="${RESULTS_DIR}/phase3-multi-container-${TS}.log"

# Print a per-source match summary against LOG_SUBSTR: a one-line count
# header followed by every matching line untruncated (so the operator can
# see the exact text TiDB / TiKV / PD log about TLS state). Analysis and
# consolidation across phases happens in the lab master doc, not here.
# Args: <label> <captured-stdout>
print_match_summary() {
  local label="$1"
  local out="$2"
  local matches
  matches="$(grep -ciE "${LOG_SUBSTR}" <<< "${out}" || true)"
  if [ "${matches}" -eq 0 ]; then
    echo "    [${label}] no matches"
    return
  fi
  echo "    [${label}] ${matches} matches:"
  grep -iE "${LOG_SUBSTR}" <<< "${out}" 2>/dev/null | sed 's/^/      /' || true
}

# Run one docker-compose pass: up, wait for TiDB status, filter logs, tear down.
# Args: <pass_label> <compose_file> <tidb_status_url>
run_compose_pass() {
  local pass_label="$1"
  local compose_file="$2"
  local tidb_status_url="$3"
  local curl_args="$4"   # extra curl args (e.g., "--cacert /certs/ca.pem" for TLS)

  echo
  echo "--- ${pass_label} (compose=${compose_file}) ---"

  cd "${LAB_DIR}"
  docker compose -f "${compose_file}" up -d

  echo "  waiting for TiDB status to respond on ${tidb_status_url} (timeout 240s)..."
  local elapsed=0
  while ! docker exec lab15-probe curl -sf ${curl_args} --max-time 5 "${tidb_status_url}" > /dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [ "${elapsed}" -gt 240 ]; then
      echo "  TIMEOUT after ${elapsed}s. Recent container logs:"
      docker compose -f "${compose_file}" logs --tail=20
      docker compose -f "${compose_file}" down --volumes 2>/dev/null || true
      return 1
    fi
  done
  echo "  cluster up after ${elapsed}s"

  # Filter via captured output + here-string. We can't use `docker logs |
  # grep -q` because under `set -o pipefail` the early grep exit SIGPIPEs
  # docker logs and the pipeline returns failure even on match. We report
  # the match COUNT (plus a sample first matching line, truncated) rather
  # than a binary match/no-match because the default '(tls|ssl)' pattern
  # matches baseline noise (PD config keys, tikv's 'openssl-vendored' feature
  # line, tidb's SQL-side warning) even when inter-component TLS is off;
  # the discrimination is in the count delta between the TLS-off and TLS-on
  # passes, not in absolute presence.
  echo "  match counts per container against LOG_SUBSTR=${LOG_SUBSTR}"
  local out
  for c in lab15-pd-0 lab15-tikv-0 lab15-tidb-0; do
    out="$(docker logs "${c}" 2>&1 || true)"
    print_match_summary "${c}" "${out}"
  done

  echo "  tearing down..."
  docker compose -f "${compose_file}" down --volumes 2>/dev/null || true
  sleep 2
}

{
  echo "=== Phase 3 - production-style multi-container startup-log probe ==="
  echo "Timestamp: ${TS}"
  echo "Substring (case-insensitive ERE): ${LOG_SUBSTR}"

  # Pass 3A: TLS off (uses docker-compose.yml; HTTP probe).
  run_compose_pass \
    "Run 3A: TLS off" \
    "docker-compose.yml" \
    "http://tidb-0:10080/status" \
    ""

  # Pass 3B: TLS on (uses docker-compose-tls.yml; HTTPS probe with --cacert).
  if [ ! -f "${LAB_DIR}/certs/ca.pem" ]; then
    echo
    echo "--- Run 3B: TLS on - SKIPPED (run ./setup-certs.sh first to generate certs) ---"
  else
    run_compose_pass \
      "Run 3B: TLS on" \
      "docker-compose-tls.yml" \
      "https://tidb-0:10080/status" \
      "--cacert /certs/ca.pem"
  fi

  echo
  echo "Expected with the default '(tls|ssl)' pattern (counts; deltas are the signal):"
  echo "  3A (TLS off) - PD ~1 (config dump SSL keys); TiKV ~2 (openssl-vendored,"
  echo "                 OpenSSL FIPS); TiDB ~2 (config dump empty cluster-ssl-*,"
  echo "                 SQL-side TLS warning)."
  echo "  3B (TLS on)  - PD higher than 3A (config dump + etcd TLS lines);"
  echo "                 TiKV higher than 3A (config dump cert paths populated);"
  echo "                 TiDB ~3A (cluster-ssl-* paths populated but on the same line)."
} | tee "${LOG}"

echo
echo "Log: ${LOG}"
