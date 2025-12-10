#!/bin/bash
set -e

# Capture charset/collation/session variables and SHOW CREATE TABLE outputs
# to prove whether UTF-8 bytes/metadata align between MySQL and TiDB.

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-Password_1234}"
MYSQL_CLIENT_IMAGE="${MYSQL_CLIENT_IMAGE:-mysql:8.0}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT_DIR="results/diagnostics-${TS}"

mkdir -p "${OUT_DIR}"

echo "Writing diagnostics to ${OUT_DIR}"

mysql_exec() {
  docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "$@"
}

tidb_exec() {
  docker run --rm --network=host -i "${MYSQL_CLIENT_IMAGE}" \
    mysql -h127.0.0.1 -P4000 -uroot "$@"
}

echo "Collecting MySQL charset/collation variables..."
mysql_exec -e "SHOW VARIABLES LIKE 'character_set_%'; SHOW VARIABLES LIKE 'collation_%';" > "${OUT_DIR}/mysql-charset-collation.txt"

echo "Collecting TiDB charset/collation variables..."
tidb_exec -e "SHOW VARIABLES LIKE 'character_set_%'; SHOW VARIABLES LIKE 'collation_%';" > "${OUT_DIR}/tidb-charset-collation.txt"

for tbl in lab.s1_blob_family lab.s2_json_test lab.s4_mixed_app; do
  echo "SHOW CREATE TABLE ${tbl} (MySQL)..."
  mysql_exec -e "SHOW CREATE TABLE ${tbl}\\G" > "${OUT_DIR}/mysql-show-create-${tbl//./_}.txt"

  echo "SHOW CREATE TABLE ${tbl} (TiDB)..."
  tidb_exec -e "SHOW CREATE TABLE ${tbl}\\G" > "${OUT_DIR}/tidb-show-create-${tbl//./_}.txt"
done

echo "Diagnostics complete."
