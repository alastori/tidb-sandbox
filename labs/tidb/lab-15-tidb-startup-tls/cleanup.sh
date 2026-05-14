#!/usr/bin/env bash
# Cleanup - tear down phase 2 playground (both TLS-off and TLS-on tags),
# phase 3 docker-compose, and phase 4 kind cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="${SCRIPT_DIR}"

TIDB_VERSION="${TIDB_VERSION:-v8.5.6}"
TAG_NO_TLS="${TAG_NO_TLS:-lab15-no-tls}"
KIND_CLUSTER="${KIND_CLUSTER:-lab15-tls}"

# Phase 3 - docker-compose (both TLS-off and TLS-on variants).
if [ -f "${LAB_DIR}/docker-compose.yml" ]; then
  ( cd "${LAB_DIR}" && docker compose -f docker-compose.yml down --volumes 2>/dev/null ) || true
fi
if [ -f "${LAB_DIR}/docker-compose-tls.yml" ]; then
  ( cd "${LAB_DIR}" && docker compose -f docker-compose-tls.yml down --volumes 2>/dev/null ) || true
fi

# Phase 2 - tiup playground (TLS-off baseline; TLS-on isn't supported by
# tiup playground so phase 2 only ever uses one tag).
tiup clean "${TAG_NO_TLS}" 2>/dev/null || true

# Belt-and-braces process kills. tiup clean kills the playground orchestrator
# but not always its spawned PD / TiKV / TiDB / TiFlash children, so we kill
# anything whose argv mentions our tag's data dir explicitly. We match by the
# data-dir path ("data/<tag>") rather than the bare tag string so we don't
# accidentally hit a kind cluster whose name happens to overlap (the kind
# cluster lab15-tls and the previous tiup tag lab15-tls used to collide).
# Use ${TAG_NO_TLS} so a custom tag override is still cleaned up.
pkill -9 -f "data/${TAG_NO_TLS}" 2>/dev/null || true
pkill -9 -f "data/lab15-tls" 2>/dev/null || true

# Also clear the per-instance tmp-storage lock TiDB writes outside the data dir
# (a re-run with the same SQL+status port hits "fslock: lock is held" otherwise).
# Matches paths like /var/folders/.../501_tidb/MTI3LjAuMC4xOjQwMDAvMC4wLjAuMDoxMDA4MA==/
rm -rf /var/folders/*/*/T/*_tidb/* 2>/dev/null || true
rm -rf /tmp/*_tidb/* 2>/dev/null || true

# tiup-spawned tidb-server / tikv-server write a few default artifacts into
# CWD (the lab dir) when phase 1 invokes them without overriding the relevant
# flags. Both are gitignored but we still wipe them so the lab dir stays tidy.
rm -f "${LAB_DIR}/tidb-slow.log" 2>/dev/null || true
rm -rf "${LAB_DIR}/oom_record" 2>/dev/null || true

# Phase 4 - kind (only if the cluster exists).
if command -v kind > /dev/null 2>&1; then
  if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER}"; then
    kind delete cluster --name "${KIND_CLUSTER}" 2>/dev/null || true
  fi
fi

sleep 2

echo "Cleanup complete."
echo "Bind state (each port should report NOT BOUND):"
for port in 4000 10080 20180 2379; do
  # `lsof` exits non-zero when nothing is listening on the port, and `grep
  # -v` exits 1 when its input is empty. Either would propagate via pipefail
  # and trip set -e, killing the loop before NOT BOUND can print. Treat the
  # empty case as empty output instead.
  bound_to=$( { lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null \
    | grep -v '^COMMAND' \
    | awk '{print $9}' \
    | head -1; } || true )
  printf "  port %-5s -> %s\n" "${port}" "${bound_to:-NOT BOUND}"
done

echo
echo "Docker containers (lab15-*) after cleanup:"
docker ps -a --filter 'name=lab15-' --format '  {{.Names}}\t{{.Status}}' || true
