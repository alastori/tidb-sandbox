#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"

{
    echo "=== Cleanup ==="

    # Stop any verification containers
    COMPOSE_FILE="${LAB_DIR}/conf/docker-compose-verify.yml"
    if [[ -f "${COMPOSE_FILE}" ]]; then
        DM_IMAGE="${DM_IMAGE_TAG}" docker compose -f "${COMPOSE_FILE}" down -v 2>/dev/null || true
    fi
    docker network rm lab00-net 2>/dev/null || true

    echo ""
    echo "To remove built images:"
    echo "  docker rmi dm:local dm:release-8.5 dm:pr-12351 ..."
    echo ""
    echo "To remove cloned tiflow repo ($(du -sh "${TIFLOW_DIR}" 2>/dev/null | cut -f1 || echo '?')):"
    echo "  rm -rf ${TIFLOW_DIR}"
    echo ""
    echo "=== Cleanup complete ==="
}
