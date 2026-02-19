#!/usr/bin/env bash
# Phase 5: JDBC Protocol Tests — MySQL Connector/J via Docker
# Tests COM_STMT_SEND_LONG_DATA, server-side prepared stmts, batch rewrite, streaming
# Prereq: tiup playground v8.5.1 running on $TIDB_PORT, Docker (Colima) running
set -euo pipefail

TIDB_PORT="${TIDB_PORT:-4000}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JDBC_DIR="$SCRIPT_DIR/jdbc-test"

echo "=== Phase 5: JDBC Protocol Tests (MySQL Connector/J 9.1.0) ==="
echo ">> TiDB port: $TIDB_PORT"

# Generate Gradle wrapper if missing (first run)
if [ ! -f "$JDBC_DIR/gradlew" ]; then
  echo ">> Generating Gradle wrapper..."
  docker run --rm \
    -v "$JDBC_DIR":/project \
    -w /project \
    gradle:8-jdk21 \
    gradle wrapper
fi

# Run the Gradle project inside a Docker container
# - Mount the project directory
# - Use host.docker.internal to reach TiDB on the host
# --add-host needed for Colima; Docker Desktop resolves
#   host.docker.internal natively
docker run --rm \
  --name varchar-jdbc-test \
  --add-host=host.docker.internal:host-gateway \
  -v "$JDBC_DIR":/project \
  -w /project \
  eclipse-temurin:21-jdk \
  bash -c "./gradlew -q run --args='host.docker.internal $TIDB_PORT'"

echo "=== Phase 5 complete ==="
