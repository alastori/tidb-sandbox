#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "ENV file not found: $ENV_FILE" >&2
  echo "Create it from .env.example (cp .env.example .env) and rerun." >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

LAB_ROOT="$SCRIPT_DIR"
RESULTS_DIR="${RESULTS_DIR:-$LAB_ROOT/results}"
mkdir -p "$RESULTS_DIR"

TS="${TS:-$(date -u +%Y%m%dT%H%M%SZ)}"

NET_NAME="${NET_NAME:-lab-net}"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-mysql-server}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0.44}"
MYSQL_CLIENT_IMAGE="${MYSQL_CLIENT_IMAGE:-$MYSQL_IMAGE}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-MyPassw0rd!}"
MYSQL_DB="${MYSQL_DB:-lab_mysqldump_sim}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYDUMPER_IMAGE="${MYDUMPER_IMAGE:-mydumper/mydumper:v0.20.1-2}"
DUMPLING_IMAGE="${DUMPLING_IMAGE:-pingcap/dumpling:v7.5.1}"

export SCRIPT_DIR LAB_ROOT RESULTS_DIR TS \
  NET_NAME MYSQL_CONTAINER MYSQL_IMAGE MYSQL_CLIENT_IMAGE MYSQL_ROOT_PASSWORD \
  MYSQL_DB MYSQL_PORT MYDUMPER_IMAGE DUMPLING_IMAGE
