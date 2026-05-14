#!/usr/bin/env bash
# Phase 1 - bare-process startup-log probe across 4 binaries x 3 config states.
#
# For each binary (tidb-server, tikv-server, pd-server, tiflash), this phase
# starts the binary briefly under three configurations and filters the startup
# log through LOG_SUBSTR (default: case-insensitive '(tls|ssl)'). Output shows
# the count delta per (binary, state) cell.
#
# State A: TLS off, no silence flag. Today's default.
# State B: TLS on. Cert paths populated in [security] section, using each
#          binary's specific key names (TiDB and TiKV/PD use different keys).
#          PD also takes https:// URL schemes so the cert config actually
#          engages. Single-binary bring-up cannot complete a TLS handshake
#          (TiKV/TiDB need PD; PD needs etcd peers) - the count delta comes
#          from cert paths landing in the loaded-config dump and the
#          security-init lines, not from a fully formed cluster.
# State C: TLS off + forward-looking silence flag. No effect today; here so
#          the harness is ready if a future TiDB release adds a startup
#          warning whose text is targetable via LOG_SUBSTR.
#
# Each binary is started in the background, given a few seconds to log, then
# stopped. We do not bring up a working cluster - we only need the startup-time
# log lines.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="${SCRIPT_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="${LAB_DIR}/results"
mkdir -p "${RESULTS_DIR}"

TIDB_VERSION="${TIDB_VERSION:-v8.5.6}"
LOG_SUBSTR="${LOG_SUBSTR:-(tls|ssl)}"
PROBE_SECONDS="${PROBE_SECONDS:-5}"

LOG="${RESULTS_DIR}/phase1-bare-process-${TS}.log"

# TiDB writes a per-instance lock under /var/folders/.../T/501_tidb/<host>/
# that survives a SIGKILL'd previous run. If we re-launch tidb-server before
# clearing it, startup fails with "fslock: lock is held". Clean before each
# tidb-server probe.
clean_tidb_locks() {
  rm -rf /var/folders/*/*/T/*_tidb/* 2>/dev/null || true
  rm -rf /tmp/*_tidb/* 2>/dev/null || true
}

# Per-binary startup wrapper. Starts the binary in background with the supplied
# config file, captures the first PROBE_SECONDS of stderr+stdout, kills it,
# then greps the captured log against LOG_SUBSTR and reports the count + a
# truncated first matching line.
probe_binary() {
  local label="$1"
  local cmd="$2"
  local out_file="${RESULTS_DIR}/${label}-${TS}.log"

  if [[ "${label}" == tidb-server-* ]]; then
    clean_tidb_locks
  fi

  ( eval "$cmd" > "${out_file}" 2>&1 & echo $! > "${out_file}.pid" ) || true
  sleep "${PROBE_SECONDS}"
  local pid; pid=$(cat "${out_file}.pid" 2>/dev/null || echo "")
  if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || true; fi
  sleep 1
  if [ -n "$pid" ]; then kill -KILL "$pid" 2>/dev/null || true; fi

  # tiup spawns the actual server (tidb-server / tikv-server / pd-server) as a
  # child process. Killing the tiup wrapper PID does not always reach the
  # child, so the binary can survive past the probe and bind to a default port
  # (e.g. tidb-server stays on :10080). That orphan then false-positives later
  # phases that use a port probe to detect cluster-up. Belt-and-braces: extract
  # the unique --config=<path> we passed in and pkill anything whose argv
  # mentions it.
  # Extract --config=<path> from cmd. The tiflash placeholder cmd has no
  # --config= and grep returns 1, which pipefail would otherwise propagate
  # and set -e would kill the script before the rest of the loop runs.
  local cfg_path=""
  cfg_path=$(printf '%s' "${cmd}" | grep -oE -- "--config=[^ ]+" 2>/dev/null | head -1 | cut -d= -f2 | tr -d "'\"" || true)
  if [ -n "${cfg_path}" ]; then
    pkill -9 -f "${cfg_path}" 2>/dev/null || true
  fi

  # Print a one-line count header followed by every matching line
  # untruncated, so the operator can see the exact text the binary logged
  # about TLS state. The default '(tls|ssl)' pattern hits baseline noise
  # too (PD config dump SSL keys, tikv 'openssl-vendored' / 'OpenSSL FIPS',
  # tidb's SQL-side TLS warning); the master doc consolidates analysis.
  local matches
  matches="$(grep -ciE "${LOG_SUBSTR}" "${out_file}" || true)"
  if [ "${matches}" -eq 0 ]; then
    echo "  [${label}] no matches"
    return
  fi
  echo "  [${label}] ${matches} matches:"
  grep -iE "${LOG_SUBSTR}" "${out_file}" 2>/dev/null | sed 's/^/    /' || true
}

write_config() {
  # write_config <path> <line(s)>
  local path="$1"; shift
  printf '%s\n' "$@" > "${path}"
}

# Run states A / B / C for one binary.
# Args:
#   1 binary_label              e.g. tidb-server
#   2 make_cmd                  function name; takes <config_path> [tls]; prints cmd
#   3 sec_ca_key                e.g. cluster-ssl-ca | ca-path | cacert-path | ca_path
#   4 sec_cert_key              e.g. cluster-ssl-cert | cert-path | cert_path
#   5 sec_key_key               e.g. cluster-ssl-key | key-path | key_path
#   6 silence_flag_key          e.g. enable-cluster-tls-warning | enable_cluster_tls_warning
run_states_for_binary() {
  local binary_label="$1"
  local make_cmd="$2"
  local sec_ca_key="$3"
  local sec_cert_key="$4"
  local sec_key_key="$5"
  local silence_flag_key="$6"

  echo
  echo "--- ${binary_label} ---"
  local tmpdir; tmpdir="$(mktemp -d)"
  trap "rm -rf '${tmpdir}'" RETURN

  # State A: no TLS, no silence flag (today's default)
  local cfg_a="${tmpdir}/a.toml"
  write_config "${cfg_a}" '# State A: no TLS, no silence flag (default)'
  probe_binary "${binary_label}-A-default" "$($make_cmd "${cfg_a}")"

  # State B: TLS configured. Cluster certs from setup-certs.sh; per-binary
  # key names; make_cmd passes 'tls' so the URL schemes flip to https where
  # the binary needs that to engage TLS (PD).
  local cert_dir="${LAB_DIR}/certs"
  if [ ! -f "${cert_dir}/ca.pem" ]; then
    echo "  [${binary_label}-B-tls-configured] SKIPPED (run ./setup-certs.sh first to generate certs)"
  else
    local cfg_b="${tmpdir}/b.toml"
    write_config "${cfg_b}" \
      '[security]' \
      "${sec_ca_key} = \"${cert_dir}/ca.pem\"" \
      "${sec_cert_key} = \"${cert_dir}/server.pem\"" \
      "${sec_key_key} = \"${cert_dir}/server-key.pem\""
    probe_binary "${binary_label}-B-tls-configured" "$($make_cmd "${cfg_b}" tls)"
  fi

  # State C: no TLS, forward-looking silence flag set. No effect today; here
  # so the harness is ready if a future TiDB release adds a startup warning.
  local cfg_c="${tmpdir}/c.toml"
  write_config "${cfg_c}" '[security]' "${silence_flag_key} = false"
  probe_binary "${binary_label}-C-silenced" "$($make_cmd "${cfg_c}")"
}

# Per-binary command-builders. Each takes <config_path> [tls] and prints the
# shell command to run the binary with the given config file. With the second
# arg set to 'tls', the URLs flip to https where applicable.
make_tidb_cmd() {
  local cfg="$1"
  # TiDB does not bind cluster URLs itself; the [security] cluster-ssl-* keys
  # only affect its outbound connections to PD and TiKV. URL scheme is fixed.
  echo "tiup tidb:${TIDB_VERSION} --store=unistore --path='' --config='${cfg}' --host=127.0.0.1 -P 0 --status=0"
}

make_tikv_cmd() {
  local cfg="$1"
  local mode="${2:-no-tls}"
  local pd_url="http://127.0.0.1:2379"
  if [ "${mode}" = "tls" ]; then
    pd_url="https://127.0.0.1:2379"
  fi
  echo "tiup tikv:${TIDB_VERSION} --addr=127.0.0.1:0 --advertise-addr=127.0.0.1:0 --status-addr=127.0.0.1:0 --pd-endpoints=${pd_url} --config='${cfg}' --data-dir=$(mktemp -d)"
}

make_pd_cmd() {
  local cfg="$1"
  local mode="${2:-no-tls}"
  local scheme="http"
  if [ "${mode}" = "tls" ]; then
    scheme="https"
  fi
  echo "tiup pd:${TIDB_VERSION} --name=pd-lab15 --client-urls=${scheme}://127.0.0.1:0 --peer-urls=${scheme}://127.0.0.1:0 --config='${cfg}' --data-dir=$(mktemp -d)"
}

make_tiflash_cmd() {
  local cfg="$1"
  # TiFlash bare-process invocation needs the official binary path; this row
  # is a placeholder. To substitute a TiFlash build path, set BINARY_PATH in
  # this script. TiFlash uses snake_case for [security] keys, so the silence
  # flag override is `enable_cluster_tls_warning`, not the kebab-case form
  # used by TiDB / TiKV / PD.
  echo "echo '(tiflash bare-process invocation needs the official binary; this row is a placeholder. See the lab README.)'"
}

{
  echo "=== Phase 1 - bare-process startup-log probe ==="
  echo "Timestamp: ${TS}"
  echo "Substring being grep'd (case-insensitive ERE): ${LOG_SUBSTR}"
  echo "Match counts per binary x state (deltas are the signal). With the default"
  echo "'(tls|ssl)' pattern: state A/C count the baseline noise (config SSL keys,"
  echo "tikv 'openssl-vendored' line, tidb SQL-side warning); state B should"
  echo "report a higher count as cluster cert paths land in the loaded-config dump"
  echo "and security-init lines (single-binary bring-up cannot complete a TLS"
  echo "handshake, since each binary needs cluster peers - for full TLS handshake"
  echo "evidence see phase 3 or phase 4)."
  echo "If a future TiDB release adds a startup warning about missing TLS, set"
  echo "LOG_SUBSTR to its text and re-run; expect state A's count to increase"
  echo "while B (TLS configured) and C (silenced via [security] flag) stay flat."

  # Per-binary [security] key names + silence-flag spelling differ across
  # repos. Source: each component's config docs.
  #   TiDB: cluster-ssl-{ca,cert,key} (Go,  kebab-case)
  #   TiKV: {ca,cert,key}-path        (Rust, kebab-case)
  #   PD:   cacert-path / cert-path / key-path (Go, kebab-case, distinct prefix)
  #   TiFlash: {ca,cert,key}_path     (C++/Poco, snake_case)
  run_states_for_binary "tidb-server" make_tidb_cmd \
    cluster-ssl-ca cluster-ssl-cert cluster-ssl-key enable-cluster-tls-warning
  run_states_for_binary "tikv-server" make_tikv_cmd \
    ca-path cert-path key-path enable-cluster-tls-warning
  run_states_for_binary "pd-server"   make_pd_cmd \
    cacert-path cert-path key-path enable-cluster-tls-warning
  run_states_for_binary "tiflash"     make_tiflash_cmd \
    ca_path cert_path key_path enable_cluster_tls_warning

  echo
  echo "Per-binary raw startup logs are in ${RESULTS_DIR}/<binary>-<state>-${TS}.log"
} | tee "${LOG}"

# tiup-spawned tidb-server / tikv-server write a few default artifacts into
# CWD (the lab dir) when invoked without overriding the relevant flags. Belt-
# and-braces: pkill any stray tidb-server / tikv-server / pd-server that
# survived per-probe cleanup, then wait briefly for any deferred fs writes
# from the dying processes to land, then wipe the artifacts. (Both files
# are gitignored, but we still wipe them so the lab dir stays tidy.) Done
# outside the `{ } | tee` block so the cleanup is in the main shell rather
# than a piped subshell whose ordering can race with backgrounded children.
pkill -9 -f "tikv-server.*--addr=127.0.0.1:0" 2>/dev/null || true
pkill -9 -f "tidb-server.*--store=unistore" 2>/dev/null || true
pkill -9 -f "pd-server.*--name=pd-lab15" 2>/dev/null || true
sleep 1
rm -f "${LAB_DIR}/tidb-slow.log" 2>/dev/null || true
rm -rf "${LAB_DIR}/oom_record" 2>/dev/null || true

echo
echo "Summary log: ${LOG}"
