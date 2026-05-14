#!/usr/bin/env bash
# Cleanup - tear down the lab14 playground and free ports.
set -euo pipefail

TIDB_VERSION="${TIDB_VERSION:-v8.5.6}"
TAG="${TAG:-lab14-bind-audit}"

tiup clean "${TAG}" 2>/dev/null || true

# Belt-and-braces: kill any lingering playground / component processes started by this lab.
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
