#!/usr/bin/env bash
# Cleanup - tear down phase 2/3 playground and phase 4 docker-compose topology.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="${SCRIPT_DIR}"

TIDB_VERSION="${TIDB_VERSION:-v8.5.6}"
TAG="${TAG:-lab14-bind-audit}"

# Phase 4 - docker-compose topology.
if [ -f "${LAB_DIR}/docker-compose.yml" ]; then
  ( cd "${LAB_DIR}" && docker compose down --volumes 2>/dev/null ) || true
fi

# Phase 2 / 3 - tiup playground.
tiup clean "${TAG}" 2>/dev/null || true

# Belt-and-braces: kill any lingering playground / component processes started by this lab.
# Note: pkill -f matches by command line, so this will also affect any other
# tiup playground v8.5.6 invocation on the host that uses the same components.
# Run with care if you have other TiDB v8.5.6 work in progress.
pkill -f "playground ${TIDB_VERSION} --tag ${TAG}" 2>/dev/null || true
pkill -f "/${TIDB_VERSION}/tidb-server" 2>/dev/null || true
pkill -f "/${TIDB_VERSION}/tikv-server" 2>/dev/null || true
pkill -f "/${TIDB_VERSION}/pd-server" 2>/dev/null || true

sleep 2

echo "Bind state after cleanup (each port should report NOT BOUND):"
for port in 4000 10080 20180 2379; do
  bound_to=$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null \
    | grep -v '^COMMAND' \
    | awk '{print $9}' \
    | head -1)
  printf "  port %-5s -> %s\n" "${port}" "${bound_to:-NOT BOUND}"
done

echo
echo "Docker containers (lab14-*) after cleanup:"
docker ps -a --filter 'name=lab14-' --format '  {{.Names}}\t{{.Status}}' || true
echo "(empty list above means cleanup was clean.)"
