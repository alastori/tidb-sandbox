#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "--- Step 1: Setup Docker network and MySQL ($MYSQL_IMAGE) ---"

# Clean previous artifacts
docker stop "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
docker rm "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NET_NAME" >/dev/null 2>&1 || true
rm -f "$LAB_ROOT/mysqldump_output.sql"
rm -rf "$LAB_ROOT/mydumper_output" "$LAB_ROOT/dumpling_output"

docker network create "$NET_NAME" >/dev/null 2>&1 || true

# Start MySQL with init script
docker run -d --name "$MYSQL_CONTAINER" \
  --network "$NET_NAME" \
  -v "$LAB_ROOT/view-dependency-create.sql:/docker-entrypoint-initdb.d/init.sql" \
  -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" \
  "$MYSQL_IMAGE" --default-authentication-plugin=mysql_native_password

echo "Waiting for MySQL to be ready..."
until docker run --rm --network "$NET_NAME" "$MYSQL_CLIENT_IMAGE" \
  mysqladmin ping -h"$MYSQL_CONTAINER" -u"root" -p"$MYSQL_ROOT_PASSWORD" --silent; do
  echo "MySQL is unavailable - sleeping"
  sleep 2
done
echo "MySQL is up and running."
