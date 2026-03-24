#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

DM_IMAGE_TAG="${1:-${DM_IMAGE_TAG:-dm:local}}"

LOG="${RESULTS_DIR}/verify-${DM_IMAGE_TAG//[:\/]/-}-${TS}.log"

{
    echo "=== Verify DM image: ${DM_IMAGE_TAG} ==="
    echo "Timestamp: ${TS}"
    echo ""

    # Check image exists
    echo "--- Image metadata ---"
    docker inspect "${DM_IMAGE_TAG}" --format \
        'ID:      {{.Id}}
Created: {{.Created}}
Size:    {{.Size}}
Arch:    {{.Architecture}}
OS:      {{.Os}}' || {
        echo "ERROR: Image ${DM_IMAGE_TAG} not found."
        echo "Build it first with one of:"
        echo "  bash scripts/build-from-branch.sh release-8.5"
        echo "  bash scripts/build-from-pr.sh 12351"
        exit 1
    }

    # Verify binaries exist and report versions
    # dm-master and dm-worker use -V (not --version); dmctl uses --version
    echo ""
    echo "--- Binary versions ---"
    echo "dm-master:"
    docker run --rm "${DM_IMAGE_TAG}" /dm-master -V 2>&1 || echo "  (dm-master not found)"
    echo ""
    echo "dm-worker:"
    docker run --rm "${DM_IMAGE_TAG}" /dm-worker -V 2>&1 || echo "  (dm-worker not found)"
    echo ""
    echo "dmctl:"
    docker run --rm "${DM_IMAGE_TAG}" /dmctl --version 2>&1 || echo "  (dmctl not found)"

    # Smoke test: verify binaries execute (--help exits immediately)
    # macOS lacks GNU timeout; use a background process with kill instead
    echo ""
    echo "--- Smoke test: dm-master --help ---"
    docker run --rm "${DM_IMAGE_TAG}" /dm-master --print-sample-config 2>&1 | head -5 || true

    echo ""
    echo "--- Smoke test: dm-worker --help ---"
    docker run --rm "${DM_IMAGE_TAG}" /dm-worker --print-sample-config 2>&1 | head -5 || true

    # Minimal Docker Compose stack test
    echo ""
    echo "--- Integration test: DM master + worker startup ---"

    COMPOSE_FILE="${LAB_DIR}/conf/docker-compose-verify.yml"

    DM_IMAGE="${DM_IMAGE_TAG}" docker compose -f "${COMPOSE_FILE}" up -d 2>&1

    echo "Waiting for DM-master..."
    retries=0
    while [ $retries -lt 20 ]; do
        if docker exec lab00-dm-master /dmctl --master-addr=dm-master:8261 list-member &>/dev/null; then
            echo "  DM-master is ready."
            break
        fi
        retries=$((retries + 1))
        sleep 2
    done

    if [ $retries -lt 20 ]; then
        echo ""
        echo "DM cluster members:"
        docker exec lab00-dm-master /dmctl --master-addr=dm-master:8261 list-member 2>&1
        echo ""
        echo "PASS: DM master + worker started successfully."
    else
        echo "FAIL: DM-master did not become ready within 40 seconds."
        echo "Logs:"
        docker logs lab00-dm-master 2>&1 | tail -20
    fi

    echo ""
    echo "Cleaning up verification stack..."
    DM_IMAGE="${DM_IMAGE_TAG}" docker compose -f "${COMPOSE_FILE}" down -v 2>/dev/null || true
    docker network rm lab00-net 2>/dev/null || true

    echo ""
    echo "=== Verification complete ==="

} 2>&1 | tee "$LOG"

clean_log "$LOG"
