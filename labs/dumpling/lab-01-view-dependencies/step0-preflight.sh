#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "--- Step 0: Pre-flight (volume mount) ---"
chmod +x "$LAB_ROOT/check_docker_env.sh"
"$LAB_ROOT/check_docker_env.sh"
