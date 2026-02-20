#!/usr/bin/env bash
# Phase 8b: ON DUPLICATE KEY UPDATE + CONCAT Hypothesis
#
# Hypothesis: ODKU with CONCAT expressions could bypass VARCHAR truncation
# if the concatenated result exceeds column limits.
#
# Tests CONCAT of literals, TEXT source columns, user variables,
# prepared statements, and pymysql binary protocol.
#
# Prereq: tiup playground v8.5.1 running on $TIDB_PORT
set -euo pipefail

TIDB_PORT="${TIDB_PORT:-4000}"
NONSTRICT="ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES"

mysql_cmd() { mysql --host 127.0.0.1 --port "$TIDB_PORT" -u root "$@"; }

echo "=== Phase 8b: ON DUPLICATE KEY UPDATE + CONCAT ==="
echo ""

mysql_cmd -e "DROP DATABASE IF EXISTS phase8b_test; CREATE DATABASE phase8b_test DEFAULT CHARSET utf8 COLLATE utf8_general_ci;"
mysql_cmd -e "SET GLOBAL sql_mode = '$NONSTRICT';"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helper: create partitioned table with unique key for ODKU
# ---------------------------------------------------------------------------
create_table() {
  mysql_cmd phase8b_test -e "
    DROP TABLE IF EXISTS t;
    CREATE TABLE t (
      id BIGINT NOT NULL AUTO_INCREMENT,
      idEmpresa BIGINT NOT NULL,
      enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
      codigoBarras VARCHAR(48) COLLATE utf8_general_ci DEFAULT NULL,
      PRIMARY KEY (id, idEmpresa) /*T![clustered_index] CLUSTERED */,
      UNIQUE KEY uk_barras (codigoBarras, idEmpresa)
    ) AUTO_ID_CACHE 1
    PARTITION BY KEY (idEmpresa) PARTITIONS 128;

    INSERT INTO t (idEmpresa, codigoBarras, enderecoDestinatario)
      VALUES (1, 'SEED', REPEAT('A', 30));
  "
}

check_oversized() {
  local test_num="$1" desc="$2"
  local max_len
  max_len=$(mysql_cmd -N phase8b_test -e "SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) FROM t;")
  if [ "$max_len" -le 70 ]; then
    printf "  8b-%-2s %-55s → max_len=%s (PASS)\n" "$test_num" "$desc" "$max_len"
    PASS=$((PASS + 1))
  else
    printf "  8b-%-2s %-55s → max_len=%s (FAIL!)\n" "$test_num" "$desc" "$max_len"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Test 8b-1: ODKU CONCAT of two long literals
# ---------------------------------------------------------------------------
echo "--- Test 8b-1: ODKU CONCAT of two long literals ---"
create_table

mysql_cmd phase8b_test -e "
SET SESSION sql_mode='$NONSTRICT';
SET NAMES utf8mb4;
INSERT INTO t (idEmpresa, codigoBarras, enderecoDestinatario)
  VALUES (1, 'SEED', 'placeholder')
ON DUPLICATE KEY UPDATE
  enderecoDestinatario = CONCAT(REPEAT('X', 100), REPEAT('Y', 100));
"

check_oversized 1 "ODKU CONCAT two literals (100+100 chars)"

# ---------------------------------------------------------------------------
# Test 8b-2: ODKU CONCAT from TEXT source column
# ---------------------------------------------------------------------------
echo "--- Test 8b-2: ODKU CONCAT from TEXT source column ---"
create_table

mysql_cmd phase8b_test -e "
DROP TABLE IF EXISTS source_text;
CREATE TABLE source_text (id INT PRIMARY KEY, big_text TEXT);
INSERT INTO source_text VALUES (1, REPEAT('T', 200));
"

mysql_cmd phase8b_test -e "
SET SESSION sql_mode='$NONSTRICT';
SET NAMES utf8mb4;
INSERT INTO t (idEmpresa, codigoBarras, enderecoDestinatario)
  VALUES (1, 'SEED', 'placeholder')
ON DUPLICATE KEY UPDATE
  enderecoDestinatario = (SELECT big_text FROM source_text WHERE id = 1);
"

check_oversized 2 "ODKU with TEXT source via subquery"

# ---------------------------------------------------------------------------
# Test 8b-3: ODKU CONCAT user variables
# ---------------------------------------------------------------------------
echo "--- Test 8b-3: ODKU CONCAT user variables ---"
create_table

mysql_cmd phase8b_test -e "
SET SESSION sql_mode='$NONSTRICT';
SET NAMES utf8mb4;
SET @long_val = REPEAT('V', 200);
INSERT INTO t (idEmpresa, codigoBarras, enderecoDestinatario)
  VALUES (1, 'SEED', 'placeholder')
ON DUPLICATE KEY UPDATE
  enderecoDestinatario = @long_val;
"

check_oversized 3 "ODKU from user variable (@long_val = 200 chars)"

# ---------------------------------------------------------------------------
# Test 8b-4: ODKU CONCAT via prepared statement
# ---------------------------------------------------------------------------
echo "--- Test 8b-4: ODKU CONCAT via prepared statement ---"
create_table

mysql_cmd phase8b_test -e "
SET SESSION sql_mode='$NONSTRICT';
SET NAMES utf8mb4;
SET @v = REPEAT('P', 200);
PREPARE stmt FROM 'INSERT INTO t (idEmpresa, codigoBarras, enderecoDestinatario) VALUES (1, ?, ?) ON DUPLICATE KEY UPDATE enderecoDestinatario = VALUES(enderecoDestinatario)';
SET @bar = 'SEED';
EXECUTE stmt USING @bar, @v;
DEALLOCATE PREPARE stmt;
"

check_oversized 4 "ODKU via prepared statement (200-char param)"

# ---------------------------------------------------------------------------
# Test 8b-5: pymysql binary protocol ODKU CONCAT
# ---------------------------------------------------------------------------
echo "--- Test 8b-5: pymysql binary protocol ODKU CONCAT ---"

if command -v python3 &>/dev/null; then
  create_table

  python3 -c "
import subprocess, sys
try:
    import pymysql
except ImportError:
    sys.exit(99)

conn = pymysql.connect(host='127.0.0.1', port=$TIDB_PORT, user='root', database='phase8b_test', charset='utf8mb4')
cur = conn.cursor()
cur.execute(\"SET SESSION sql_mode='$NONSTRICT'\")
long_val = 'Q' * 200
cur.execute(
    'INSERT INTO t (idEmpresa, codigoBarras, enderecoDestinatario) VALUES (%s, %s, %s) '
    'ON DUPLICATE KEY UPDATE enderecoDestinatario = VALUES(enderecoDestinatario)',
    (1, 'SEED', long_val)
)
conn.commit()
conn.close()
" 2>/dev/null
  rc=$?

  if [ "$rc" -eq 99 ]; then
    printf "  8b-%-2s %-55s → SKIPPED (pymysql not installed)\n" "5" "pymysql binary protocol ODKU CONCAT"
  else
    check_oversized 5 "pymysql binary protocol ODKU CONCAT"
  fi
else
  printf "  8b-%-2s %-55s → SKIPPED (python3 not available)\n" "5" "pymysql binary protocol ODKU CONCAT"
fi

# ---------------------------------------------------------------------------
# Cleanup & Summary
# ---------------------------------------------------------------------------
echo ""
mysql_cmd -e "DROP DATABASE IF EXISTS phase8b_test;"

echo "=== Phase 8b Summary ==="
echo "  Pass: $PASS / $((PASS + FAIL))"
echo "  Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  *** BYPASS DETECTED — ODKU + CONCAT bypasses VARCHAR truncation ***"
  exit 1
else
  echo "  ODKU + CONCAT does NOT bypass VARCHAR truncation on v8.5.1"
fi
