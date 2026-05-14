#!/usr/bin/env bash
# Phase 4 - TiDB Operator on kind. Two sequential passes against one kind
# cluster:
#
#   4A. TLS off: kubectl apply -f kind/tidb-cluster-no-tls.yaml in namespace
#       lab15a. spec.tlsCluster.enabled is unset (today's default).
#   4B. TLS on:  kubectl apply -f kind/tidb-cluster-tls.yaml in namespace
#       lab15b. cert-manager Issuer + per-component Certificates produce the
#       Secrets the operator looks up; spec.tlsCluster.enabled = true.
#
# For each pass, filters each pod's startup log through LOG_SUBSTR (default:
# case-insensitive '(tls|ssl)'). With the default pattern: pass 4A logs no
# TLS handshake lines from PD/TiKV (TiDB has unrelated SQL-side noise);
# pass 4B logs TLS-related lines for PD as etcd's client TLS starts and for
# TiKV inside its config dump (cert paths visible).
#
# Heaviest of the four phases (requires kind, helm, kubectl; the script also
# installs cert-manager on first run).
#
# Forward-looking: if a future TiDB release adds a startup warning about
# missing inter-component TLS, set LOG_SUBSTR to that warning text and re-run.
# Pass 4A should print the warning; pass 4B should stay silent (TLS configured).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="${SCRIPT_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="${LAB_DIR}/results"
mkdir -p "${RESULTS_DIR}"

KIND_CLUSTER="${KIND_CLUSTER:-lab15-tls}"
TIDB_OPERATOR_VERSION="${TIDB_OPERATOR_VERSION:-v1.6.5}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"
LOG_SUBSTR="${LOG_SUBSTR:-(tls|ssl)}"

LOG="${RESULTS_DIR}/phase4-operator-kind-${TS}.log"

# Check for required binaries; bail with a helpful message if any are missing.
require_bin() {
  local bin="$1"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "ERROR: ${bin} not on PATH. Install with: brew install ${bin}" >&2
    return 1
  fi
}

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

# Count log lines from a pod's named container. Returns 0 if the pod doesn't
# exist yet, the container hasn't started, or the apiserver hasn't buffered any
# lines. Wrapped to neutralize pipefail when kubectl logs fails.
# Args: <namespace> <pod> [container]
count_log_lines() {
  local ns="$1"
  local pod="$2"
  local container="${3:-}"
  local out
  if [ -n "${container}" ]; then
    out="$(kubectl logs -n "${ns}" "${pod}" -c "${container}" 2>/dev/null || true)"
  else
    out="$(kubectl logs -n "${ns}" "${pod}" 2>/dev/null || true)"
  fi
  printf '%s' "${out}" | grep -c '' || true
}

# Wait until all expected pods exist AND each one's main container has logged
# at least N lines. We can't rely on `phase=Running` (transitions before logs
# appear) or `condition=Ready` (the slowlog-prober sidecar can lag).
# Args: <namespace>
wait_for_pods_logged() {
  local ns="$1"
  local elapsed=0
  while true; do
    local pd_n tikv_n tidb_n
    pd_n="$(count_log_lines "${ns}" lab15-pd-0)"
    tikv_n="$(count_log_lines "${ns}" lab15-tikv-0)"
    tidb_n="$(count_log_lines "${ns}" lab15-tidb-0 tidb)"
    if [ "${pd_n}" -ge 20 ] && [ "${tikv_n}" -ge 20 ] && [ "${tidb_n}" -ge 20 ]; then
      echo "  pd/tikv/tidb all logging after ${elapsed}s (lines: pd=${pd_n} tikv=${tikv_n} tidb=${tidb_n})"
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
    if [ "${elapsed}" -gt 600 ]; then
      echo "  TIMEOUT after ${elapsed}s. Lines: pd=${pd_n} tikv=${tikv_n} tidb=${tidb_n}. Pods:"
      kubectl get pods -n "${ns}" 2>&1
      return 1
    fi
  done
}

# Run one pass: create namespace, apply manifest, wait for tidb-0, filter
# logs, tear down namespace.
# Args: <pass_label> <namespace> <manifest_path>
run_operator_pass() {
  local pass_label="$1"
  local ns="$2"
  local manifest="$3"

  echo
  echo "--- ${pass_label} (namespace=${ns}, manifest=${manifest}) ---"

  # If a previous interrupted run left the namespace behind (or the previous
  # pass's async delete is still terminating), wait for it to fully disappear
  # before recreating. Otherwise the apply lands in stale state and
  # wait_for_pods_logged reads logs from the previous cluster.
  if kubectl get namespace "${ns}" >/dev/null 2>&1; then
    echo "  namespace ${ns} already exists; deleting and waiting for full removal..."
    kubectl delete namespace "${ns}" --wait=false 2>/dev/null || true
    local waited=0
    until ! kubectl get namespace "${ns}" >/dev/null 2>&1; do
      sleep 5
      waited=$((waited + 5))
      if [ "${waited}" -gt 180 ]; then
        echo "  TIMEOUT after ${waited}s waiting for namespace ${ns} to terminate."
        return 1
      fi
    done
    echo "  namespace ${ns} fully removed after ${waited}s; recreating fresh."
  fi
  kubectl create namespace "${ns}"
  kubectl apply -n "${ns}" -f "${manifest}"

  echo "  waiting for pd/tikv/tidb to all start logging (timeout 600s)..."
  wait_for_pods_logged "${ns}"

  # Filter via captured output + here-string. We can't use `kubectl logs |
  # grep -q` because under `set -o pipefail` the early grep exit SIGPIPEs
  # kubectl and the pipeline returns failure even on match. We report the
  # match COUNT (plus a sample first matching line, truncated) rather than a
  # binary match/no-match because the default '(tls|ssl)' pattern matches
  # baseline noise (PD config keys, tikv's 'openssl-vendored' feature line,
  # tidb's SQL-side warning) even when inter-component TLS is off; the
  # discrimination is in the count delta between the TLS-off and TLS-on
  # passes, not in absolute presence.
  echo "  match counts per pod against LOG_SUBSTR=${LOG_SUBSTR}"
  local out
  for pod in lab15-pd-0 lab15-tikv-0; do
    out="$(kubectl logs -n "${ns}" "${pod}" 2>/dev/null || true)"
    print_match_summary "${pod}" "${out}"
  done
  out="$(kubectl logs -n "${ns}" lab15-tidb-0 -c tidb 2>/dev/null || true)"
  print_match_summary "lab15-tidb-0" "${out}"

  echo "  tearing down namespace ${ns}..."
  kubectl delete namespace "${ns}" --wait=false 2>&1 || true
}

{
  echo "=== Phase 4 - TiDB Operator on kind ==="
  echo "Timestamp: ${TS}"
  echo "Kind cluster: ${KIND_CLUSTER}"
  echo "TiDB Operator: ${TIDB_OPERATOR_VERSION}"
  echo "cert-manager: ${CERT_MANAGER_VERSION}"
  echo "Substring (case-insensitive ERE): ${LOG_SUBSTR}"

  require_bin kind
  require_bin helm
  require_bin kubectl

  # Step 1: kind cluster (idempotent; reuse if already present).
  if ! kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
    echo
    echo "--- Setup: creating kind cluster ${KIND_CLUSTER} ---"
    kind create cluster --name "${KIND_CLUSTER}"
  else
    echo
    echo "--- Setup: reusing existing kind cluster ${KIND_CLUSTER} ---"
    kubectl config use-context "kind-${KIND_CLUSTER}"
  fi

  # Step 2: tidb-operator CRDs (server-side apply; the TidbCluster CRD exceeds
  # client-side annotation size).
  echo
  echo "--- Setup: applying tidb-operator CRDs (${TIDB_OPERATOR_VERSION}) ---"
  kubectl apply --server-side -f \
    "https://raw.githubusercontent.com/pingcap/tidb-operator/${TIDB_OPERATOR_VERSION}/manifests/crd.yaml" >/dev/null

  # Step 3: tidb-operator helm chart (idempotent).
  if ! helm status tidb-operator -n tidb-admin >/dev/null 2>&1; then
    echo
    echo "--- Setup: helm install tidb-operator ${TIDB_OPERATOR_VERSION} ---"
    helm repo add pingcap https://charts.pingcap.org/ 2>/dev/null || true
    helm repo update pingcap >/dev/null
    helm install --namespace tidb-admin --create-namespace tidb-operator \
      pingcap/tidb-operator --version "${TIDB_OPERATOR_VERSION}"
  else
    echo
    echo "--- Setup: tidb-operator already installed ---"
  fi
  echo "  waiting for tidb-controller-manager Available..."
  kubectl wait --for=condition=Available --timeout=180s \
    deployment/tidb-controller-manager -n tidb-admin

  # Step 4: cert-manager (needed by pass 4B).
  if ! kubectl get namespace cert-manager >/dev/null 2>&1; then
    echo
    echo "--- Setup: kubectl apply cert-manager ${CERT_MANAGER_VERSION} ---"
    kubectl apply -f \
      "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" >/dev/null
  else
    echo
    echo "--- Setup: cert-manager already installed ---"
  fi
  echo "  waiting for cert-manager deployments Available..."
  kubectl wait --for=condition=Available --timeout=240s deployment --all -n cert-manager

  # Pass 4A: TLS off.
  run_operator_pass \
    "Run 4A: TLS off" \
    "lab15a" \
    "${LAB_DIR}/kind/tidb-cluster-no-tls.yaml"

  # Pass 4B: TLS on.
  run_operator_pass \
    "Run 4B: TLS on" \
    "lab15b" \
    "${LAB_DIR}/kind/tidb-cluster-tls.yaml"

  echo
  echo "Expected with the default '(tls|ssl)' pattern (counts; deltas are the signal):"
  echo "  4A (TLS off) - PD ~1 (config dump SSL keys); TiKV ~2 (openssl-vendored,"
  echo "                 OpenSSL FIPS); TiDB ~2 (config dump empty cluster-ssl-*,"
  echo "                 SQL-side TLS warning)."
  echo "  4B (TLS on)  - PD ~3 (config dump + etcd peer TLS + etcd client TLS);"
  echo "                 TiKV ~3 (4A noise + config dump cert paths populated);"
  echo "                 TiDB ~2 (4A noise; the cluster-ssl-* paths in the config"
  echo "                 dump are populated but still match the same line)."
  echo
  echo "Note: namespaces are cleaned up but the kind cluster ${KIND_CLUSTER}, the"
  echo "tidb-operator install, and cert-manager are left in place for re-runs."
  echo "To remove the cluster entirely: kind delete cluster --name ${KIND_CLUSTER}"
} | tee "${LOG}"

echo
echo "Log: ${LOG}"
