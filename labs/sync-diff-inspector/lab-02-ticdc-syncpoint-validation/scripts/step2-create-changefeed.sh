#!/bin/bash
set -euo pipefail

TICDC_VERSION="${TICDC_VERSION:-v8.5.5-release.3}"
CHANGEFEED_ID="${CHANGEFEED_ID:-syncpoint-lab-cf}"
SYNC_POINT_INTERVAL="${SYNC_POINT_INTERVAL:-30s}"

echo "=== Creating changefeed with syncpoint enabled ==="

# Create changefeed with syncpoint
tiup cdc:${TICDC_VERSION} cli changefeed create \
    --pd="http://127.0.0.1:2379" \
    --changefeed-id="${CHANGEFEED_ID}" \
    --sink-uri="mysql://root@127.0.0.1:14000/" \
    --config=/dev/stdin <<EOF
enable-sync-point = true
sync-point-interval = "${SYNC_POINT_INTERVAL}"
sync-point-retention = "1h"
EOF

sleep 5

echo "=== Verifying changefeed status ==="
tiup cdc:${TICDC_VERSION} cli changefeed query \
    --pd="http://127.0.0.1:2379" \
    --changefeed-id="${CHANGEFEED_ID}"

echo "=== Changefeed created successfully ==="
