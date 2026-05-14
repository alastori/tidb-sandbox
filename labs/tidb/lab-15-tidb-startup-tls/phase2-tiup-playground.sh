#!/usr/bin/env bash
# Phase 2 - tiup playground TLS-off baseline.
#
# Only one pass: 2A. Default (no TLS).
#
# `tiup playground` does NOT expose a TLS flag (verified up to v1.16.5; --tls
# is not recognized). Per-component [security] configs via --db.config /
# --kv.config / --pd.config can configure cert paths for individual binaries,
# but playground hard-codes http:// in the inter-component URLs it wires up
# (--pd, --advertise-client-urls, etc.), so the cluster fails to form when
# any one component requires TLS. Net: playground cannot demonstrate the
# TLS-on side of the count delta. Phases 1, 3, and 4 cover TLS-on across
# bare-process, multi-container, and TiDB Operator respectively.
#
# This phase is therefore a baseline-only run: it confirms the TLS-off counts
# in the playground deployment context and serves as the smallest end-to-end
# `tiup playground` smoke against a configurable LOG_SUBSTR.
#
# Forward-looking: if a future TiDB release adds a startup warning about
# missing inter-component TLS, set LOG_SUBSTR to that warning text and re-run
# to verify the warning fires in the playground startup logs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="${SCRIPT_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="${LAB_DIR}/results"
mkdir -p "${RESULTS_DIR}"

TIDB_VERSION="${TIDB_VERSION:-v8.5.6}"
TAG_NO_TLS="${TAG_NO_TLS:-lab15-no-tls}"
LOG_SUBSTR="${LOG_SUBSTR:-(tls|ssl)}"

LOG="${RESULTS_DIR}/phase2-tiup-playground-${TS}.log"

# Run one playground, wait for TiDB status to bind, grep per-component logs,
# tear down, return.
run_playground_pass() {
  local pass_label="$1"
  local tag="$2"
  shift 2
  local extra_args="$*"

  echo
  echo "--- ${pass_label} (tag=${tag}, extra=${extra_args:-none}) ---"
  tiup playground "${TIDB_VERSION}" --tag "${tag}" \
    --db 1 --kv 1 --pd 1 --tiflash 1 --without-monitor ${extra_args} \
    > "${RESULTS_DIR}/playground-${tag}-${TS}.log" 2>&1 &
  local pg_pid=$!
  echo "playground PID ${pg_pid}"

  # Wait until each of the 4 component subdirs (tidb-0, tikv-0, pd-0,
  # tiflash-0) has logged at least 30 substantive lines. We deliberately do
  # NOT probe port 10080 because a stale tidb-server from another phase could
  # be bound to it, false-positiving "cluster up after 0s" before this
  # playground has produced any logs of its own. We can't just check that the
  # log FILES exist because tiup creates the files on launch but tiflash in
  # particular keeps them empty for 30-60s while it bootstraps; we want grep
  # to run after the bootstrap-phase log lines have actually landed.
  echo "  waiting for all 4 playground components to log >=30 lines each in ${HOME}/.tiup/data/${tag} (timeout 240s)..."
  local data_dir="${HOME}/.tiup/data/${tag}"
  local elapsed=0
  while true; do
    local ready=1
    for comp in tidb tikv pd tiflash; do
      local total_lines=0
      # Pre-test the dir to avoid pipefail noise when find fails on a missing
      # path. Don't use `|| echo 0` as a fallback: that emits a second line
      # which trips bash's integer comparison further down.
      if [ -d "${data_dir}/${comp}-0" ]; then
        total_lines=$(find "${data_dir}/${comp}-0" -maxdepth 1 -name '*.log' -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
      fi
      if [ "${total_lines:-0}" -lt 30 ]; then
        ready=0
        break
      fi
    done
    if [ "${ready}" = "1" ]; then
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    if [ "${elapsed}" -gt 240 ]; then
      echo "  TIMEOUT after ${elapsed}s waiting for all 4 components to log >=30 lines. Recent playground log:"
      tail -30 "${RESULTS_DIR}/playground-${tag}-${TS}.log"
      tiup clean "${tag}" 2>/dev/null || true
      return 1
    fi
  done
  echo "  all 4 playground components logging in ${data_dir} after ${elapsed}s"

  # Print a one-line per-component count header followed by every matching
  # line untruncated (each line prefixed with the source log file's
  # basename so cross-file matches are distinguishable). Analysis lives in
  # the master doc; this script just dumps raw evidence.
  echo "  match dump per component against LOG_SUBSTR=${LOG_SUBSTR}"
  local local_data="${HOME}/.tiup/data/${tag}"
  for comp in tidb tikv pd tiflash; do
    local total=0
    for log in $(find "${local_data}/${comp}-0" -name '*.log' 2>/dev/null); do
      local n
      n="$(grep -ciE "${LOG_SUBSTR}" "${log}" || true)"
      total=$((total + n))
    done
    if [ "${total}" -eq 0 ]; then
      echo "    [${comp}] no matches"
    else
      echo "    [${comp}] ${total} matches:"
      for log in $(find "${local_data}/${comp}-0" -name '*.log' 2>/dev/null); do
        grep -iE "${LOG_SUBSTR}" "${log}" 2>/dev/null | sed "s|^|      [${log##*/}] |" || true
      done
    fi
  done

  echo "  tearing down ${tag}..."
  tiup clean "${tag}" 2>/dev/null || true
  # Match by data-dir argv ("data/<tag>") rather than the bare tag string so we
  # don't accidentally hit a kind cluster whose name happens to share characters.
  pkill -f "playground ${TIDB_VERSION} --tag ${tag}" 2>/dev/null || true
  pkill -f "data/${tag}" 2>/dev/null || true
  sleep 3
}

{
  echo "=== Phase 2 - tiup playground TLS-off baseline (TiDB ${TIDB_VERSION}) ==="
  echo "Timestamp: ${TS}"
  echo "Substring grep: ${LOG_SUBSTR}"

  run_playground_pass "Run 2A: TLS off (default; only mode tiup playground supports)" "${TAG_NO_TLS}"

  echo
  echo "Expected with the default '(tls|ssl)' LOG_SUBSTR:"
  echo "  Low baseline counts per component (config dump SSL keys, tikv"
  echo "  openssl-vendored, tidb SQL-side TLS warning). For the TLS-on count"
  echo "  delta, see phase 1 (bare process), phase 3 (multi-container), or"
  echo "  phase 4 (TiDB Operator)."
} | tee "${LOG}"

echo
echo "Log: ${LOG}"
