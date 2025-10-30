#!/usr/bin/env bash
set -euo pipefail
export COMPOSE_DOCKER_CLI_BUILD=1
export DOCKER_BUILDKIT=1

# Tip: override with TIDB_TAG=v8.5.0 for GA runs
: "${TIDB_TAG:=nightly}"
export TIDB_TAG

docker compose up -d
"$(dirname "$0")/wait-for-tidb.sh"
