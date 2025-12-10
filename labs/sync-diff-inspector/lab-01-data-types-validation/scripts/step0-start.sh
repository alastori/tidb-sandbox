#!/bin/bash
set -e

echo "=== Starting MySQL and TiDB containers ==="

# Default images (override via MYSQL_IMAGE/TIDB_IMAGE/MYSQL_CLIENT_IMAGE if you want digests)
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0}"
MYSQL_CLIENT_IMAGE="${MYSQL_CLIENT_IMAGE:-$MYSQL_IMAGE}"
TIDB_IMAGE="${TIDB_IMAGE:-pingcap/tidb:v8.5.4}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-Password_1234}"

# Check if containers already exist and remove them
docker rm -f mysql8sd 2>/dev/null || true
docker rm -f tidbsd 2>/dev/null || true

# Start MySQL 8.0 (exposed on port 3307)
echo "Starting MySQL 8.0 on port 3307..."
docker run --name mysql8sd \
    -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
    -p 3307:3306 \
    -d "${MYSQL_IMAGE}"

# Start TiDB (MySQL protocol on port 4000)
echo "Starting TiDB on port 4000..."
docker run --name tidbsd \
    -p 4000:4000 \
    -d "${TIDB_IMAGE}"

# Wait for databases to be ready
echo "Waiting for MySQL to be ready..."
for i in {1..30}; do
    if docker exec mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1" &>/dev/null; then
        echo "MySQL is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "MySQL failed to start"
        exit 1
    fi
    sleep 1
done

echo "Waiting for TiDB to be ready..."
for i in {1..30}; do
    if docker run --rm --network=host "${MYSQL_CLIENT_IMAGE}" mysql -h127.0.0.1 -P4000 -uroot -e "SELECT 1" &>/dev/null; then
        echo "TiDB is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "TiDB failed to start"
        exit 1
    fi
    sleep 1
done

# Verify versions
echo ""
echo "=== Database Versions ==="
echo "MySQL version:"
docker exec mysql8sd mysql -h127.0.0.1 -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT VERSION();"
echo ""
echo "TiDB version:"
docker run --rm --network=host "${MYSQL_CLIENT_IMAGE}" mysql -h127.0.0.1 -P4000 -uroot -e "SELECT VERSION();"

echo ""
echo "=== Containers started successfully ==="
