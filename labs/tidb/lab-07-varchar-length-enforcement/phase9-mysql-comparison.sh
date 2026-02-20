#!/usr/bin/env bash
# Phase 9: MySQL 8.0 Side-by-Side Comparison
#
# Runs the 16 confirmed TiDB bypass scenarios against both MySQL 8.0 (Docker)
# and TiDB, displaying results side-by-side to prove MySQL truncates correctly
# in every case where TiDB doesn't.
#
# Prereqs:
#   - Docker available (docker info)
#   - tiup playground v8.5.1 running on $TIDB_PORT
#
# Skipped tests (not meaningful for MySQL comparison):
#   E2  — ASCII baseline (both correct, not a bypass)
#   E5  — STRICT mode (both reject correctly)
#   E6  — utf8mb4 column (both truncate correctly, no charset mismatch)
#   E7  — tidb_skip_utf8_check (TiDB-specific variable)
#   E10 — UPDATE (TiDB already correct)
#   E11 — ODKU (TiDB already correct)
#   E17 — Binary collation (TiDB already correct)
#   E21 — tidb_check_mb4_value_in_utf8 (TiDB-specific variable)
set -euo pipefail

TIDB_PORT="${TIDB_PORT:-4000}"
MYSQL_PORT="${MYSQL_PORT:-3307}"
MYSQL_CONTAINER="phase9-mysql-compare"
NONSTRICT_TIDB="ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES"
# MySQL 8.0 removed NO_AUTO_CREATE_USER — use equivalent non-strict mode
NONSTRICT_MY="ERROR_FOR_DIVISION_BY_ZERO,ALLOW_INVALID_DATES"

# ---------------------------------------------------------------------------
# Docker lifecycle
# ---------------------------------------------------------------------------
cleanup() {
  echo ""
  echo "--- Cleaning up MySQL container ---"
  docker rm -f "$MYSQL_CONTAINER" &>/dev/null || true
}
trap cleanup EXIT

echo "=== Phase 9: MySQL 8.0 vs TiDB Side-by-Side Comparison ==="
echo ""

# Check Docker
if ! docker info &>/dev/null; then
  echo "ERROR: Docker is not available. Please start Docker first."
  exit 1
fi

# Start MySQL 8.0
echo "--- Starting MySQL 8.0 container (port $MYSQL_PORT) ---"
docker rm -f "$MYSQL_CONTAINER" &>/dev/null || true
docker run -d \
  --name "$MYSQL_CONTAINER" \
  -p "$MYSQL_PORT":3306 \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_ROOT_HOST='%' \
  mysql:8.0 \
  --default-authentication-plugin=mysql_native_password \
  --character-set-server=utf8 \
  --collation-server=utf8_general_ci \
  --secure-file-priv="" >/dev/null

# Wait for MySQL readiness
echo -n "Waiting for MySQL 8.0"
for i in $(seq 1 60); do
  if mysql --host 127.0.0.1 --port "$MYSQL_PORT" -u root -proot -e "SELECT 1" &>/dev/null; then
    echo " ready (${i}s)"
    break
  fi
  echo -n "."
  sleep 1
  if [ "$i" -eq 60 ]; then
    echo " TIMEOUT"
    echo "ERROR: MySQL 8.0 failed to start within 60 seconds."
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Command helpers
# ---------------------------------------------------------------------------
mysql_tidb() { mysql --host 127.0.0.1 --port "$TIDB_PORT" -u root "$@"; }
mysql_my()   { mysql --host 127.0.0.1 --port "$MYSQL_PORT" -u root -proot "$@" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Setup databases
# ---------------------------------------------------------------------------
echo ""
echo "--- Setting up test databases ---"
mysql_tidb -e "DROP DATABASE IF EXISTS phase9_cmp; CREATE DATABASE phase9_cmp DEFAULT CHARSET utf8 COLLATE utf8_general_ci;"
mysql_tidb -e "SET GLOBAL sql_mode = '$NONSTRICT_TIDB';"

mysql_my -e "DROP DATABASE IF EXISTS phase9_cmp; CREATE DATABASE phase9_cmp DEFAULT CHARSET utf8 COLLATE utf8_general_ci;"
mysql_my -e "SET GLOBAL sql_mode = '$NONSTRICT_MY';"

echo "  TiDB sql_mode: $(mysql_tidb -N -e "SELECT @@GLOBAL.sql_mode;" 2>/dev/null)"
echo "  MySQL sql_mode: $(mysql_my -N -e "SELECT @@GLOBAL.sql_mode;")"
echo ""

# ---------------------------------------------------------------------------
# Test framework
# ---------------------------------------------------------------------------
TIDB_BUGS=0
MYSQL_BUGS=0
TOTAL=0

# Run a test against both engines and display side-by-side
# Usage: run_compare <test_num> <description> <limit> [col]
run_compare() {
  local test_num="$1" desc="$2" limit="$3" col="${4:-val}"
  TOTAL=$((TOTAL + 1))

  local tidb_len mysql_len tidb_tag mysql_tag

  tidb_len=$(mysql_tidb -N phase9_cmp -e "SELECT MAX(CHAR_LENGTH($col)) FROM t;" 2>/dev/null || echo "NULL")
  mysql_len=$(mysql_my -N phase9_cmp -e "SELECT MAX(CHAR_LENGTH($col)) FROM t;" 2>/dev/null || echo "NULL")

  # Trim whitespace
  tidb_len=$(echo "$tidb_len" | tr -d '[:space:]')
  mysql_len=$(echo "$mysql_len" | tr -d '[:space:]')

  if [ -z "$tidb_len" ] || [ "$tidb_len" = "NULL" ]; then
    tidb_tag="NULL"
  elif [ "$tidb_len" -le "$limit" ]; then
    tidb_tag="CORRECT"
  else
    tidb_tag="BUG!"
    TIDB_BUGS=$((TIDB_BUGS + 1))
  fi

  if [ -z "$mysql_len" ] || [ "$mysql_len" = "NULL" ]; then
    mysql_tag="NULL"
  elif [ "$mysql_len" -le "$limit" ]; then
    mysql_tag="CORRECT"
  else
    mysql_tag="BUG!"
    MYSQL_BUGS=$((MYSQL_BUGS + 1))
  fi

  printf "  E%-2s %-45s | TiDB char_len=%-3s (%s) | MySQL char_len=%-3s (%s)\n" \
    "$test_num" "$desc" "${tidb_len:-NULL}" "$tidb_tag" "${mysql_len:-NULL}" "$mysql_tag"
}

# ---------------------------------------------------------------------------
# Helper: create standard table on both engines
# Usage: create_table_both <sql>
# ---------------------------------------------------------------------------
create_table_both() {
  local sql="$1"
  mysql_tidb phase9_cmp -e "DROP TABLE IF EXISTS t; $sql" 2>/dev/null
  mysql_my phase9_cmp -e "DROP TABLE IF EXISTS t; $sql" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: run SQL on both engines
# ---------------------------------------------------------------------------
run_both() {
  local sql="$1"
  mysql_tidb phase9_cmp -e "$sql" 2>/dev/null
  mysql_my phase9_cmp -e "$sql" 2>/dev/null
}

# ===========================================================================
# Tests — 16 TiDB bypass scenarios
# ===========================================================================

echo "=== Running 16 bypass scenarios ==="
echo ""

# --- E1: Core repro ---
echo "--- E1: VARCHAR(10) utf8 + emoji INSERT (core repro) ---"
create_table_both "CREATE TABLE t (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
);"
run_both "SET NAMES utf8mb4; INSERT INTO t (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');"
run_compare 1 "VARCHAR(10) utf8 + emoji (core repro)" 10

# --- E3: Multiple emoji types ---
echo "--- E3: Multiple emoji types ---"
create_table_both "CREATE TABLE t (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
);"
run_both "SET NAMES utf8mb4; INSERT INTO t (val) VALUES ('📝📓🖍😀📝📓🖍😀📝📓🖍😀📝📓🖍');"
run_compare 3 "Multiple emoji types into VARCHAR(10)" 10

# --- E4: Partitioned gnre schema ---
echo "--- E4: Partitioned gnre schema + emoji ---"
# TiDB: partitioned table
mysql_tidb phase9_cmp -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT,
    idEmpresa BIGINT NOT NULL,
    enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL DEFAULT '',
    PRIMARY KEY (id, idEmpresa) /*T![clustered_index] CLUSTERED */
  ) AUTO_ID_CACHE 1
  PARTITION BY KEY (idEmpresa) PARTITIONS 128;
  SET NAMES utf8mb4;
  INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES
    (1, 'Rua das Flores 123 📝 Bairro Centro 📓 Sao Paulo SP 01234-567 📝 Ref proximo ao mercado 📓 Apto 45B');
" 2>/dev/null
# MySQL: non-partitioned equivalent (TiDB partition syntax not compatible)
mysql_my phase9_cmp -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    idEmpresa BIGINT NOT NULL,
    enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL DEFAULT ''
  );
  SET NAMES utf8mb4;
  INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES
    (1, 'Rua das Flores 123 📝 Bairro Centro 📓 Sao Paulo SP 01234-567 📝 Ref proximo ao mercado 📓 Apto 45B');
" 2>/dev/null
run_compare 4 "Partitioned gnre VARCHAR(70) + emoji" 70 enderecoDestinatario

# --- E8: Mixed utf8 text + embedded emoji ---
echo "--- E8: Mixed utf8 text + embedded emoji ---"
create_table_both "CREATE TABLE t (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
);"
run_both "SET NAMES utf8mb4; INSERT INTO t (val) VALUES ('Ola📝Mundo📓Teste🖍Dados');"
run_compare 8 "Mixed utf8 + emoji" 10

# --- E9: Brazilian addresses + emoji ---
echo "--- E9: Brazilian addresses + emoji ---"
create_table_both "CREATE TABLE t (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  val VARCHAR(70) COLLATE utf8_general_ci DEFAULT NULL
);"
run_both "SET NAMES utf8mb4; INSERT INTO t (val) VALUES
  ('Rua Augusta 1234 📝 Consolacao 📓 Sao Paulo SP 01304-001 📝 Apto 501 Torre B 📓 Ref mercado'),
  ('Av Paulista 1000 😀 Bela Vista 📝 SP 01310-100 📓 Sala 1805 Conj 18 Ed Top Center 📝 Proximo MASP'),
  ('R Mercado Livre 📝📓🖍😀 Osasco SP 06233-030 Galpao 7 Doca 12 Bloco C 📝 NF 987654');"
run_compare 9 "Brazilian addresses + emoji VARCHAR(70)" 70

# --- E12: REPLACE INTO ---
echo "--- E12: REPLACE INTO + emoji ---"
create_table_both "CREATE TABLE t (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
);"
run_both "INSERT INTO t (id, val) VALUES (1, 'seed');"
run_both "SET NAMES utf8mb4; REPLACE INTO t (id, val) VALUES (1, 'ABCDE📝FGHIJ📓KLMNO🖍PQRST');"
run_compare 12 "REPLACE INTO + emoji VARCHAR(10)" 10

# --- E13: INSERT...SELECT from utf8mb4 source ---
echo "--- E13: INSERT...SELECT from utf8mb4 source ---"
mysql_tidb phase9_cmp -e "
  DROP TABLE IF EXISTS src; DROP TABLE IF EXISTS t;
  CREATE TABLE src (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, val VARCHAR(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci DEFAULT NULL);
  CREATE TABLE t (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL);
  INSERT INTO src (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');
  INSERT INTO t (val) SELECT val FROM src;
" 2>/dev/null
mysql_my phase9_cmp -e "
  DROP TABLE IF EXISTS src; DROP TABLE IF EXISTS t;
  CREATE TABLE src (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, val VARCHAR(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci DEFAULT NULL);
  CREATE TABLE t (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL);
  INSERT INTO src (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');
  INSERT INTO t (val) SELECT val FROM src;
" 2>/dev/null
run_compare 13 "INSERT...SELECT from utf8mb4 source" 10

# --- E14: User variable with emoji ---
echo "--- E14: User variable with emoji ---"
create_table_both "CREATE TABLE t (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
);"
run_both "SET NAMES utf8mb4; SET @v = 'ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ'; INSERT INTO t (val) VALUES (@v);"
run_compare 14 "User variable with emoji VARCHAR(10)" 10

# --- E15: CONCAT with emoji ---
echo "--- E15: CONCAT with emoji components ---"
create_table_both "CREATE TABLE t (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
);"
run_both "SET NAMES utf8mb4; INSERT INTO t (val) VALUES (CONCAT('ABCDE', '📝', 'FGHIJ', '📓', 'KLMNO'));"
run_compare 15 "CONCAT with emoji VARCHAR(10)" 10

# --- E16: CHAR(10) column ---
echo "--- E16: CHAR(10) column with emoji ---"
create_table_both "CREATE TABLE t (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  val CHAR(10) COLLATE utf8_general_ci DEFAULT NULL
);"
run_both "SET NAMES utf8mb4; INSERT INTO t (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');"
run_compare 16 "CHAR(10) utf8 + emoji" 10

# --- E18: LOAD DATA with emoji ---
echo "--- E18: LOAD DATA with emoji ---"
TMPCSV=$(mktemp "${TMPDIR%/}/phase9_cmp_XXXXXXXX.csv")
printf '1,ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ\n' > "$TMPCSV"

# TiDB
mysql_tidb phase9_cmp -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (id BIGINT NOT NULL PRIMARY KEY, val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL);
  SET GLOBAL local_infile = 1;
" 2>/dev/null
mysql_tidb --local-infile=1 phase9_cmp -e "
  LOAD DATA LOCAL INFILE '$TMPCSV' INTO TABLE t FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' (id, val);
" 2>/dev/null || true

# MySQL — LOAD DATA via docker exec (server-side INFILE, secure-file-priv disabled)
docker cp "$TMPCSV" "$MYSQL_CONTAINER":/tmp/phase9_cmp.csv 2>/dev/null || true
docker exec "$MYSQL_CONTAINER" chmod 644 /tmp/phase9_cmp.csv 2>/dev/null || true
mysql_my phase9_cmp -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (id BIGINT NOT NULL PRIMARY KEY, val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL);
" 2>/dev/null
docker exec "$MYSQL_CONTAINER" mysql -u root -proot --default-character-set=utf8mb4 phase9_cmp -e "
  SET sql_mode = '$NONSTRICT_MY';
  LOAD DATA INFILE '/tmp/phase9_cmp.csv' INTO TABLE t
    CHARACTER SET utf8mb4
    FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' (id, val);
" 2>/dev/null || true

run_compare 18 "LOAD DATA with emoji VARCHAR(10)" 10
rm -f "$TMPCSV"

# --- E20: Multi-row INSERT mixed emoji/ASCII ---
echo "--- E20: Multi-row INSERT mixed emoji/ASCII ---"
create_table_both "CREATE TABLE t (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
);"
run_both "SET NAMES utf8mb4; INSERT INTO t (val) VALUES
  (REPEAT('A', 30)),
  ('Short📝Long📓Extra🖍Data'),
  (REPEAT('B', 25)),
  ('No emoji but very long string exceeding limit');"
run_compare 20 "Multi-row INSERT mixed emoji/ASCII" 10

# --- E22: NOT NULL column with emoji ---
echo "--- E22: NOT NULL column with emoji ---"
create_table_both "CREATE TABLE t (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  val VARCHAR(10) COLLATE utf8_general_ci NOT NULL DEFAULT ''
);"
run_both "SET NAMES utf8mb4; INSERT INTO t (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');"
run_compare 22 "NOT NULL VARCHAR(10) + emoji" 10

# --- E23: PREPARE/EXECUTE with emoji ---
# MySQL 8.0 rejects PREPARE with utf8mb4→utf8 collation mismatch (ERROR 3988),
# which is stricter than TiDB. We show MySQL as CORRECT (error = no oversized data).
echo "--- E23: Server-side PREPARE/EXECUTE with emoji ---"
create_table_both "CREATE TABLE t (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
);"
mysql_tidb phase9_cmp -e "
  SET NAMES utf8mb4;
  SET @v = 'ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ';
  PREPARE stmt FROM 'INSERT INTO t (val) VALUES (?)';
  EXECUTE stmt USING @v;
  DEALLOCATE PREPARE stmt;
" 2>/dev/null || true
mysql_result_e23=$(mysql_my phase9_cmp -e "
  SET NAMES utf8mb4;
  SET @v = 'ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ';
  PREPARE stmt FROM 'INSERT INTO t (val) VALUES (?)';
  EXECUTE stmt USING @v;
  DEALLOCATE PREPARE stmt;
" 2>&1 || true)

TOTAL=$((TOTAL + 1))
tidb_len_e23=$(mysql_tidb -N phase9_cmp -e "SELECT MAX(CHAR_LENGTH(val)) FROM t;" 2>/dev/null || echo "NULL")
tidb_len_e23=$(echo "$tidb_len_e23" | tr -d '[:space:]')
mysql_len_e23=$(mysql_my -N phase9_cmp -e "SELECT MAX(CHAR_LENGTH(val)) FROM t;" 2>/dev/null || echo "NULL")
mysql_len_e23=$(echo "$mysql_len_e23" | tr -d '[:space:]')

if [ -n "$tidb_len_e23" ] && [ "$tidb_len_e23" != "NULL" ] && [ "$tidb_len_e23" -gt 10 ]; then
  tidb_tag_e23="BUG!"
  TIDB_BUGS=$((TIDB_BUGS + 1))
else
  tidb_tag_e23="CORRECT"
fi

if echo "$mysql_result_e23" | grep -qiE "ERROR|3988|impossible"; then
  mysql_tag_e23="CORRECT (ERROR)"
  mysql_len_e23="ERR"
else
  if [ -z "$mysql_len_e23" ] || [ "$mysql_len_e23" = "NULL" ] || [ "$mysql_len_e23" -le 10 ]; then
    mysql_tag_e23="CORRECT"
  else
    mysql_tag_e23="BUG!"
    MYSQL_BUGS=$((MYSQL_BUGS + 1))
  fi
fi

printf "  E%-2s %-45s | TiDB char_len=%-3s (%s) | MySQL char_len=%-3s (%s)\n" \
  "23" "PREPARE/EXECUTE with emoji" "${tidb_len_e23:-NULL}" "$tidb_tag_e23" "$mysql_len_e23" "$mysql_tag_e23"

# --- E24: JSON_EXTRACT emoji → utf8 column ---
echo "--- E24: JSON_EXTRACT emoji → utf8 column ---"
mysql_tidb phase9_cmp -e "
  DROP TABLE IF EXISTS src; DROP TABLE IF EXISTS t;
  CREATE TABLE src (id INT PRIMARY KEY, doc JSON);
  CREATE TABLE t (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL);
  SET NAMES utf8mb4;
  INSERT INTO src VALUES (1, JSON_OBJECT('addr', 'ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ'));
  INSERT INTO t (val) SELECT JSON_UNQUOTE(JSON_EXTRACT(doc, '\$.addr')) FROM src;
" 2>/dev/null
mysql_my phase9_cmp -e "
  DROP TABLE IF EXISTS src; DROP TABLE IF EXISTS t;
  CREATE TABLE src (id INT PRIMARY KEY, doc JSON);
  CREATE TABLE t (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL);
  SET NAMES utf8mb4;
  INSERT INTO src VALUES (1, JSON_OBJECT('addr', 'ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ'));
  INSERT INTO t (val) SELECT JSON_UNQUOTE(JSON_EXTRACT(doc, '\$.addr')) FROM src;
" 2>/dev/null
run_compare 24 "JSON_EXTRACT emoji → utf8 VARCHAR(10)" 10

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=== Comparison Summary ==="
echo "  Tests run:       $TOTAL"
echo "  TiDB bypasses:   $TIDB_BUGS / $TOTAL"
echo "  MySQL bypasses:  $MYSQL_BUGS / $TOTAL"
echo ""
if [ "$TIDB_BUGS" -gt 0 ] && [ "$MYSQL_BUGS" -eq 0 ]; then
  echo "  MySQL correctly truncates in all $TIDB_BUGS scenarios where TiDB bypasses."
  echo "  Both systems used equivalent non-strict sql_mode (no STRICT_TRANS_TABLES) and SET NAMES utf8mb4."
elif [ "$MYSQL_BUGS" -gt 0 ]; then
  echo "  UNEXPECTED: MySQL also showed bypasses. Check results above."
else
  echo "  No bypasses detected in either system."
fi

# Cleanup databases
mysql_tidb -e "SET GLOBAL sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';" 2>/dev/null
mysql_tidb -e "DROP DATABASE IF EXISTS phase9_cmp;" 2>/dev/null
mysql_my -e "DROP DATABASE IF EXISTS phase9_cmp;" 2>/dev/null
