#!/usr/bin/env bash
# Phase 6: sql_mode Variation Stress Tests
# Tests every sql_mode combination, mid-transaction changes,
# and GLOBAL vs SESSION interactions.
# Prereq: tiup playground v8.5.1 running on $TIDB_PORT
set -euo pipefail

TIDB_PORT="${TIDB_PORT:-4000}"
NONSTRICT="ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES"

echo "=== Phase 6: sql_mode Variation Tests ==="
echo ">> TiDB port: $TIDB_PORT"

MYSQL="mysql --host 127.0.0.1 --port $TIDB_PORT -u root"

$MYSQL -e "CREATE DATABASE IF NOT EXISTS sqlmode_test;"

test_sqlmode() {
  local id="$1"
  local desc="$2"
  local mode="$3"

  result=$($MYSQL -N -e "
    USE sqlmode_test;
    DROP TABLE IF EXISTS t;
    CREATE TABLE t (
      id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
      nome VARCHAR(120) COLLATE utf8_general_ci
        DEFAULT NULL
    );
    SET SESSION sql_mode = '$mode';
    INSERT INTO t (nome) VALUES (REPEAT('A', 500));
    SELECT MAX(CHAR_LENGTH(nome)) FROM t;
  " 2>&1)

  if echo "$result" | grep -q "ERROR"; then
    err=$(echo "$result" | grep "ERROR" | head -1 \
      | sed 's/.*ERROR/ERROR/')
    printf "  %-5s %-42s -> %s\n" "$id" "$desc" "$err"
  else
    charlen=$(echo "$result" | tail -1 | tr -d '[:space:]')
    printf "  %-5s %-42s -> char_len=%s\n" \
      "$id" "$desc" "$charlen"
  fi
}

echo ""
echo "--- Strict variants (expect ERROR 1406) ---"
test_sqlmode "S1" "STRICT_ALL_TABLES" \
  "STRICT_ALL_TABLES"
test_sqlmode "S2" "STRICT_ALL_TABLES + reported extras" \
  "STRICT_ALL_TABLES,$NONSTRICT"
test_sqlmode "S3" "TRADITIONAL" \
  "TRADITIONAL"

echo ""
echo "--- Non-strict variants (expect truncation) ---"
test_sqlmode "S4" "ANSI" "ANSI"
test_sqlmode "S5" "PAD_CHAR_TO_FULL_LENGTH" \
  "PAD_CHAR_TO_FULL_LENGTH"
test_sqlmode "S6" "PAD_CHAR + reported non-strict" \
  "PAD_CHAR_TO_FULL_LENGTH,$NONSTRICT"
test_sqlmode "S7" "ONLY_FULL_GROUP_BY alone" \
  "ONLY_FULL_GROUP_BY"
test_sqlmode "S8" "NO_ZERO_DATE,NO_ZERO_IN_DATE" \
  "NO_ZERO_DATE,NO_ZERO_IN_DATE"
test_sqlmode "S9" "ANSI_QUOTES" "ANSI_QUOTES"
test_sqlmode "S10" "REAL_AS_FLOAT,NO_BACKSLASH_ESCAPES" \
  "REAL_AS_FLOAT,NO_BACKSLASH_ESCAPES"
test_sqlmode "S15" "All non-strict flags combined" \
  "ALLOW_INVALID_DATES,ANSI_QUOTES,ERROR_FOR_DIVISION_BY_ZERO,HIGH_NOT_PRECEDENCE,IGNORE_SPACE,NO_AUTO_CREATE_USER,NO_AUTO_VALUE_ON_ZERO,NO_BACKSLASH_ESCAPES,NO_DIR_IN_CREATE,NO_ENGINE_SUBSTITUTION,NO_UNSIGNED_SUBTRACTION,NO_ZERO_DATE,NO_ZERO_IN_DATE,ONLY_FULL_GROUP_BY,PAD_CHAR_TO_FULL_LENGTH,PIPES_AS_CONCAT,REAL_AS_FLOAT"

echo ""
echo "--- GLOBAL/SESSION interactions ---"

# S11: strict -> non-strict mid-transaction
result=$($MYSQL -N -e "
  USE sqlmode_test;
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    nome VARCHAR(120) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET SESSION sql_mode = 'STRICT_TRANS_TABLES';
  BEGIN;
  INSERT INTO t (nome) VALUES ('short_value');
  SET SESSION sql_mode = '$NONSTRICT';
  INSERT INTO t (nome) VALUES (REPEAT('A', 500));
  COMMIT;
  SELECT MAX(CHAR_LENGTH(nome)) FROM t;
" 2>&1)
charlen=$(echo "$result" | tail -1 | tr -d '[:space:]')
printf "  %-5s %-42s -> char_len=%s\n" \
  "S11" "strict->non-strict mid-txn" "$charlen"

# S12: non-strict -> strict mid-transaction
result=$($MYSQL -N -e "
  USE sqlmode_test;
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    nome VARCHAR(120) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET SESSION sql_mode = '$NONSTRICT';
  BEGIN;
  INSERT INTO t (nome) VALUES ('short_value');
  SET SESSION sql_mode = 'STRICT_TRANS_TABLES';
  INSERT INTO t (nome) VALUES (REPEAT('A', 500));
  COMMIT;
  SELECT MAX(CHAR_LENGTH(nome)) FROM t;
" 2>&1)
if echo "$result" | grep -q "ERROR"; then
  err=$(echo "$result" | grep "ERROR" | head -1 \
    | sed 's/.*ERROR/ERROR/')
  printf "  %-5s %-42s -> %s\n" \
    "S12" "non-strict->strict mid-txn" "$err"
else
  charlen=$(echo "$result" | tail -1 | tr -d '[:space:]')
  printf "  %-5s %-42s -> char_len=%s\n" \
    "S12" "non-strict->strict mid-txn" "$charlen"
fi

# S13: GLOBAL strict, SESSION non-strict
result=$($MYSQL -N -e "
  USE sqlmode_test;
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    nome VARCHAR(120) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET GLOBAL sql_mode = 'STRICT_TRANS_TABLES';
  SET SESSION sql_mode = '$NONSTRICT';
  INSERT INTO t (nome) VALUES (REPEAT('A', 500));
  SELECT MAX(CHAR_LENGTH(nome)) FROM t;
" 2>&1)
charlen=$(echo "$result" | tail -1 | tr -d '[:space:]')
printf "  %-5s %-42s -> char_len=%s\n" \
  "S13" "GLOBAL strict, SESSION non-strict" "$charlen"

# S14: GLOBAL non-strict, SESSION strict
result=$($MYSQL -N -e "
  USE sqlmode_test;
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    nome VARCHAR(120) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET GLOBAL sql_mode = '$NONSTRICT';
  SET SESSION sql_mode = 'STRICT_TRANS_TABLES';
  INSERT INTO t (nome) VALUES (REPEAT('A', 500));
  SELECT MAX(CHAR_LENGTH(nome)) FROM t;
" 2>&1)
if echo "$result" | grep -q "ERROR"; then
  err=$(echo "$result" | grep "ERROR" | head -1 \
    | sed 's/.*ERROR/ERROR/')
  printf "  %-5s %-42s -> %s\n" \
    "S14" "GLOBAL non-strict, SESSION strict" "$err"
else
  charlen=$(echo "$result" | tail -1 | tr -d '[:space:]')
  printf "  %-5s %-42s -> char_len=%s\n" \
    "S14" "GLOBAL non-strict, SESSION strict" "$charlen"
fi

# Reset GLOBAL sql_mode to TiDB default
$MYSQL -N -e "
  SET GLOBAL sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
"

echo ""
echo "=== Phase 6 complete ==="
