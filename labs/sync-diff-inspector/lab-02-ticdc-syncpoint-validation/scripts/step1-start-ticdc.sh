#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"
TS=$(date +%Y%m%d-%H%M%S)

TICDC_VERSION="${TICDC_VERSION:-v8.5.5-release.3}"

mkdir -p "${LAB_DIR}/results"

echo "=== Starting TiCDC (new architecture) ==="

# Start TiCDC server connecting to upstream PD
tiup cdc:${TICDC_VERSION} server \
    --pd="http://127.0.0.1:2379" \
    --addr="0.0.0.0:8300" \
    --advertise-addr="127.0.0.1:8300" \
    --log-file="${LAB_DIR}/results/ticdc-${TS}.log" &

sleep 10

echo "=== Verifying TiCDC is running ==="
tiup cdc:${TICDC_VERSION} cli capture list --pd="http://127.0.0.1:2379"

echo "=== TiCDC started successfully ==="
