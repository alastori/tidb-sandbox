#!/usr/bin/env bash
# Phase 9: Multi-byte Charset Bypass Reproduction
#
# Root cause identified during customer live session (2026-02-20):
# Inserting utf8mb4 characters (emojis) into a utf8 column in non-strict
# sql_mode triggers Warning 1366 ("Incorrect string value"). TiDB replaces
# the invalid bytes but SKIPS VARCHAR length truncation. The mangled string
# lands in full, exceeding the column limit.
#
# MySQL handles this correctly: replace invalid chars AND truncate to the
# VARCHAR limit. TiDB only does the first part.
#
# Prereq: tiup playground v8.5.1 running on $TIDB_PORT
set -euo pipefail

TIDB_PORT="${TIDB_PORT:-4000}"
NONSTRICT="ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES"
STRICT="ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION"

mysql_cmd() { mysql --host 127.0.0.1 --port "$TIDB_PORT" -u root "$@"; }

echo "=== Phase 9: Multi-byte Charset Bypass ==="
echo ""

mysql_cmd -e "DROP DATABASE IF EXISTS phase9_test; CREATE DATABASE phase9_test DEFAULT CHARSET utf8 COLLATE utf8_general_ci;"
mysql_cmd -e "SET GLOBAL sql_mode = '$NONSTRICT';"

PASS=0
BUG=0

# ---------------------------------------------------------------------------
# Helper: check if stored char_len exceeds the VARCHAR limit
# ---------------------------------------------------------------------------
check_result() {
  local test_num="$1" desc="$2" limit="$3" col="${4:-val}"
  local char_len
  char_len=$(mysql_cmd -N phase9_test -e "SELECT MAX(CHAR_LENGTH($col)) FROM t;" 2>/dev/null)
  if [ -z "$char_len" ] || [ "$char_len" = "NULL" ]; then
    printf "  E%-2s %-58s -> char_len=NULL\n" "$test_num" "$desc"
    PASS=$((PASS + 1))
  elif [ "$char_len" -le "$limit" ]; then
    printf "  E%-2s %-58s -> char_len=%-3s (CORRECT)\n" "$test_num" "$desc" "$char_len"
    PASS=$((PASS + 1))
  else
    printf "  E%-2s %-58s -> char_len=%-3s (BUG! limit=%s)\n" "$test_num" "$desc" "$char_len" "$limit"
    BUG=$((BUG + 1))
  fi
}

# ---------------------------------------------------------------------------
# E1: Core repro — VARCHAR(10) utf8, emoji INSERT, non-strict
# Customer scenario: VARCHAR(10) storing char_len >> 10
# ---------------------------------------------------------------------------
echo "--- E1: VARCHAR(10) utf8 + emoji INSERT (core repro) ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');
" 2>/dev/null
check_result 1 "VARCHAR(10) utf8 + emoji (core repro)" 10

# Detail output for the core test
mysql_cmd -N phase9_test -e "
  SELECT id,
    CHAR_LENGTH(val) AS char_len,
    LENGTH(val) AS byte_len,
    LEFT(HEX(val), 80) AS hex_prefix
  FROM t;
" 2>/dev/null | while read -r id clen blen hex; do
  printf "       id=%s char_len=%-3s byte_len=%-3s hex=%.60s\n" "$id" "$clen" "$blen" "$hex"
done
echo ""

# ---------------------------------------------------------------------------
# E2: ASCII baseline — plain ASCII in VARCHAR(10) still truncates correctly
# ---------------------------------------------------------------------------
echo "--- E2: ASCII baseline (no emoji) ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES (REPEAT('A', 50));
" 2>/dev/null
check_result 2 "ASCII-only REPEAT('A', 50) into VARCHAR(10)" 10
echo ""

# ---------------------------------------------------------------------------
# E3: Multiple emoji types — diverse 4-byte codepoints
# ---------------------------------------------------------------------------
echo "--- E3: Multiple emoji types ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES ('📝📓🖍😀📝📓🖍😀📝📓🖍😀📝📓🖍');
" 2>/dev/null
check_result 3 "Multiple emoji types (15 emojis) into VARCHAR(10)" 10
echo ""

# ---------------------------------------------------------------------------
# E4: Partitioned table — gnre-like schema + emoji INSERT
# ---------------------------------------------------------------------------
echo "--- E4: Partitioned gnre schema + emoji ---"
mysql_cmd phase9_test -e "
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
check_result 4 "Partitioned gnre VARCHAR(70) + emoji" 70 enderecoDestinatario
echo ""

# ---------------------------------------------------------------------------
# E5: STRICT_TRANS_TABLES — should reject with ERROR
# ---------------------------------------------------------------------------
echo "--- E5: STRICT_TRANS_TABLES mode ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
" 2>/dev/null

result=$(mysql_cmd phase9_test -e "
  SET SESSION sql_mode = '$STRICT';
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES ('ABCDE📝FGHIJ📓KLMNO');
" 2>&1 || true)

if echo "$result" | grep -qiE "ERROR|1406|1366|Data too long|Incorrect string"; then
  printf "  E%-2s %-58s -> ERROR (CORRECT)\n" "5" "STRICT mode rejects emoji insert"
  PASS=$((PASS + 1))
else
  char_len=$(mysql_cmd -N phase9_test -e "SELECT MAX(CHAR_LENGTH(val)) FROM t;" 2>/dev/null)
  if [ -n "$char_len" ] && [ "$char_len" != "NULL" ] && [ "$char_len" -le 10 ]; then
    printf "  E%-2s %-58s -> char_len=%-3s (CORRECT)\n" "5" "STRICT mode + emoji" "$char_len"
    PASS=$((PASS + 1))
  else
    printf "  E%-2s %-58s -> char_len=%-3s (BUG!)\n" "5" "STRICT mode + emoji" "${char_len:-NULL}"
    BUG=$((BUG + 1))
  fi
fi

# Reset to non-strict for remaining tests
mysql_cmd -e "SET GLOBAL sql_mode = '$NONSTRICT';"
echo ""

# ---------------------------------------------------------------------------
# E6: utf8mb4 table charset — emoji is valid, expect normal truncation
# ---------------------------------------------------------------------------
echo "--- E6: utf8mb4 table charset (no charset mismatch) ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');
" 2>/dev/null
check_result 6 "utf8mb4 column (no mismatch, expect truncation)" 10
echo ""

# ---------------------------------------------------------------------------
# E7: tidb_skip_utf8_check=ON — skips validation, no Warning 1366 path
# ---------------------------------------------------------------------------
echo "--- E7: tidb_skip_utf8_check=ON ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET tidb_skip_utf8_check = ON;
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');
" 2>/dev/null
check_result 7 "skip_utf8_check=ON + emoji into VARCHAR(10)" 10
mysql_cmd -e "SET GLOBAL tidb_skip_utf8_check = OFF;" 2>/dev/null
echo ""

# ---------------------------------------------------------------------------
# E8: Mixed content — valid utf8 text + embedded emoji exceeding limit
# ---------------------------------------------------------------------------
echo "--- E8: Mixed utf8 text + embedded emoji ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES ('Ola📝Mundo📓Teste🖍Dados');
" 2>/dev/null
check_result 8 "Mixed utf8 + emoji ('Ola📝Mundo📓Teste🖍Dados')" 10
echo ""

# ---------------------------------------------------------------------------
# E9: Production-realistic — Brazilian addresses with emoji
# ---------------------------------------------------------------------------
echo "--- E9: Brazilian address with emoji (production pattern) ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(70) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES
    ('Rua Augusta 1234 📝 Consolacao 📓 Sao Paulo SP 01304-001 📝 Apto 501 Torre B 📓 Ref mercado'),
    ('Av Paulista 1000 😀 Bela Vista 📝 SP 01310-100 📓 Sala 1805 Conj 18 Ed Top Center 📝 Proximo MASP'),
    ('R Mercado Livre 📝📓🖍😀 Osasco SP 06233-030 Galpao 7 Doca 12 Bloco C 📝 NF 987654');
" 2>/dev/null
check_result 9 "Brazilian addresses + emoji into VARCHAR(70)" 70

# Per-row detail
mysql_cmd -N phase9_test -e "
  SELECT id,
    CHAR_LENGTH(val) AS char_len,
    LENGTH(val) AS byte_len
  FROM t ORDER BY id;
" 2>/dev/null | while read -r id clen blen; do
  printf "       id=%s char_len=%-3s byte_len=%-3s\n" "$id" "$clen" "$blen"
done
echo ""

# ---------------------------------------------------------------------------
# E10: UPDATE path — does UPDATE also bypass?
# ---------------------------------------------------------------------------
echo "--- E10: UPDATE with emoji content ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  INSERT INTO t (val) VALUES ('short');
  SET NAMES utf8mb4;
  UPDATE t SET val = 'ABCDE📝FGHIJ📓KLMNO' WHERE id = 1;
" 2>/dev/null
check_result 10 "UPDATE with emoji into VARCHAR(10)" 10
echo ""

# ---------------------------------------------------------------------------
# E11: ON DUPLICATE KEY UPDATE with emoji
# ---------------------------------------------------------------------------
echo "--- E11: ODKU with emoji ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  INSERT INTO t (id, val) VALUES (1, 'seed');
  SET NAMES utf8mb4;
  INSERT INTO t (id, val) VALUES (1, 'ABCDE📝FGHIJ📓KLMNO🖍PQRST')
    ON DUPLICATE KEY UPDATE val = VALUES(val);
" 2>/dev/null
check_result 11 "ODKU with emoji into VARCHAR(10)" 10
echo ""

# ---------------------------------------------------------------------------
# E12: REPLACE INTO with emoji content
# ---------------------------------------------------------------------------
echo "--- E12: REPLACE INTO with emoji ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  INSERT INTO t (id, val) VALUES (1, 'seed');
  SET NAMES utf8mb4;
  REPLACE INTO t (id, val) VALUES (1, 'ABCDE📝FGHIJ📓KLMNO🖍PQRST');
" 2>/dev/null
check_result 12 "REPLACE INTO with emoji into VARCHAR(10)" 10
echo ""

# ===========================================================================
# Additional scenarios — different write paths and expression types (E13-E24)
# ===========================================================================
echo "--- Additional write-path scenarios ---"
echo ""

# ---------------------------------------------------------------------------
# E13: INSERT ... SELECT from utf8mb4 source table
# Source table has utf8mb4 column, target has utf8 — charset mismatch
# triggers Warning 1366 when data crosses charset boundary
# ---------------------------------------------------------------------------
echo "--- E13: INSERT ... SELECT from utf8mb4 source ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS src;
  DROP TABLE IF EXISTS t;
  CREATE TABLE src (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci DEFAULT NULL
  );
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  INSERT INTO src (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');
  INSERT INTO t (val) SELECT val FROM src;
" 2>/dev/null
check_result 13 "INSERT...SELECT from utf8mb4 source into VARCHAR(10) utf8" 10
echo ""

# ---------------------------------------------------------------------------
# E14: User variable with emoji
# SET @v = emoji_string; INSERT INTO t VALUES (@v);
# User variables may have utf8mb4 collation
# ---------------------------------------------------------------------------
echo "--- E14: User variable with emoji ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  SET @v = 'ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ';
  INSERT INTO t (val) VALUES (@v);
" 2>/dev/null
check_result 14 "User variable with emoji into VARCHAR(10) utf8" 10
echo ""

# ---------------------------------------------------------------------------
# E15: CONCAT producing oversized string with emoji
# Expression path: CONCAT(ascii, emoji) → utf8 column
# ---------------------------------------------------------------------------
echo "--- E15: CONCAT with emoji components ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES (CONCAT('ABCDE', '📝', 'FGHIJ', '📓', 'KLMNO'));
" 2>/dev/null
check_result 15 "CONCAT with emoji into VARCHAR(10) utf8" 10
echo ""

# ---------------------------------------------------------------------------
# E16: CHAR(N) column (not VARCHAR) — different truncation/padding logic
# CHAR has different truncation/padding logic (right-pads with spaces)
# ---------------------------------------------------------------------------
echo "--- E16: CHAR(10) column with emoji ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val CHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');
" 2>/dev/null
check_result 16 "CHAR(10) utf8 + emoji" 10
echo ""

# ---------------------------------------------------------------------------
# E17: Binary source collation → utf8 target
# Binary collation uses a different conversion path that may handle
# truncation differently
# ---------------------------------------------------------------------------
echo "--- E17: Binary collation source → utf8 column ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES binary;
  INSERT INTO t (val) VALUES ('ABCDE\xF0\x9F\x93\x9DFGHIJ\xF0\x9F\x93\x93KLMNO\xF0\x9F\x96\x8DPQRST');
" 2>/dev/null
check_result 17 "Binary collation source with mb4 bytes into VARCHAR(10)" 10
echo ""

# ---------------------------------------------------------------------------
# E18: LOAD DATA with emoji content
# LOAD DATA imports file data through the same write path as INSERT
# ---------------------------------------------------------------------------
echo "--- E18: LOAD DATA with emoji ---"
TMPCSV=$(mktemp "$TMPDIR/phase9_XXXXXX.csv")
printf '1,ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ\n' > "$TMPCSV"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET GLOBAL local_infile = 1;
" 2>/dev/null
mysql_cmd --local-infile=1 phase9_test -e "
  LOAD DATA LOCAL INFILE '$TMPCSV' INTO TABLE t
  FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' (id, val);
" 2>/dev/null
check_result 18 "LOAD DATA with emoji into VARCHAR(10) utf8" 10
rm -f "$TMPCSV"
echo ""

# ---------------------------------------------------------------------------
# E19: Prepared statement (pymysql binary protocol) with emoji
# Binary protocol may handle charset differently at network layer
# ---------------------------------------------------------------------------
echo "--- E19: pymysql binary protocol INSERT with emoji ---"
if command -v python3 &>/dev/null; then
  mysql_cmd phase9_test -e "
    DROP TABLE IF EXISTS t;
    CREATE TABLE t (
      id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
      val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
    );
  " 2>/dev/null

  python3 -c "
import sys
try:
    import pymysql
except ImportError:
    sys.exit(99)
conn = pymysql.connect(host='127.0.0.1', port=$TIDB_PORT, user='root', database='phase9_test', charset='utf8mb4')
cur = conn.cursor()
cur.execute(\"SET SESSION sql_mode='$NONSTRICT'\")
emoji_str = 'ABCDE\U0001F4DDFGHIJ\U0001F4D3KLMNO\U0001F58DPQRST\U0001F4DDUVWXYZ'
cur.execute('INSERT INTO t (val) VALUES (%s)', (emoji_str,))
conn.commit()
conn.close()
" 2>/dev/null
  rc=$?

  if [ "$rc" -eq 99 ]; then
    printf "  E%-2s %-58s -> SKIPPED (pymysql not installed)\n" "19" "pymysql binary protocol + emoji"
  else
    check_result 19 "pymysql binary protocol INSERT with emoji" 10
  fi
else
  printf "  E%-2s %-58s -> SKIPPED (python3 not available)\n" "19" "pymysql binary protocol + emoji"
fi
echo ""

# ---------------------------------------------------------------------------
# E20: Multi-row INSERT — some rows with emoji, some without
# Tests whether per-row charset error affects truncation of other rows
# ---------------------------------------------------------------------------
echo "--- E20: Multi-row INSERT mixed emoji/ASCII ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES
    (REPEAT('A', 30)),
    ('Short📝Long📓Extra🖍Data'),
    (REPEAT('B', 25)),
    ('No emoji but very long string exceeding limit');
" 2>/dev/null
# Check each row individually
mysql_cmd -N phase9_test -e "
  SELECT id,
    CHAR_LENGTH(val) AS char_len
  FROM t ORDER BY id;
" 2>/dev/null | {
  any_bug=0
  while read -r id clen; do
    if [ "$clen" -gt 10 ]; then
      printf "       id=%s char_len=%-3s (BUG!)\n" "$id" "$clen"
      any_bug=1
    else
      printf "       id=%s char_len=%-3s (correct)\n" "$id" "$clen"
    fi
  done
  if [ "$any_bug" -eq 1 ]; then
    printf "  E%-2s %-58s -> BUG (some rows exceed limit)\n" "20" "Multi-row INSERT mixed emoji/ASCII"
  else
    printf "  E%-2s %-58s -> CORRECT\n" "20" "Multi-row INSERT mixed emoji/ASCII"
  fi
}
# Fix counter outside subshell
max_len=$(mysql_cmd -N phase9_test -e "SELECT MAX(CHAR_LENGTH(val)) FROM t;" 2>/dev/null)
if [ -n "$max_len" ] && [ "$max_len" -gt 10 ]; then
  BUG=$((BUG + 1))
else
  PASS=$((PASS + 1))
fi
echo ""

# ---------------------------------------------------------------------------
# E21: check_mb4_value_in_utf8=OFF as workaround
# When OFF, skips MB4-in-UTF8 validation → no charset error →
# truncation runs normally → should be CORRECT
# ---------------------------------------------------------------------------
echo "--- E21: check_mb4_value_in_utf8=OFF (potential workaround) ---"
# Note: this is a global config, not a session variable. Use tidb_check_mb4_value_in_utf8
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET GLOBAL tidb_check_mb4_value_in_utf8 = OFF;
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');
" 2>/dev/null
check_result 21 "check_mb4_value_in_utf8=OFF + emoji (workaround?)" 10
mysql_cmd -e "SET GLOBAL tidb_check_mb4_value_in_utf8 = ON;" 2>/dev/null
echo ""

# ---------------------------------------------------------------------------
# E22: NOT NULL column (production uses NOT NULL, E1 uses DEFAULT NULL)
# ---------------------------------------------------------------------------
echo "--- E22: NOT NULL column with emoji ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci NOT NULL DEFAULT ''
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');
" 2>/dev/null
check_result 22 "NOT NULL VARCHAR(10) utf8 + emoji" 10
echo ""

# ---------------------------------------------------------------------------
# E23: Prepared statement via SQL PREPARE/EXECUTE with emoji
# Server-side prepared statement path
# ---------------------------------------------------------------------------
echo "--- E23: Server-side PREPARE/EXECUTE with emoji ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  SET @v = 'ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ';
  PREPARE stmt FROM 'INSERT INTO t (val) VALUES (?)';
  EXECUTE stmt USING @v;
  DEALLOCATE PREPARE stmt;
" 2>/dev/null
check_result 23 "PREPARE/EXECUTE with emoji into VARCHAR(10)" 10
echo ""

# ---------------------------------------------------------------------------
# E24: JSON_EXTRACT producing emoji → utf8 column
# JSON stores utf8mb4 natively; extracting into utf8 column crosses charset
# ---------------------------------------------------------------------------
echo "--- E24: JSON_EXTRACT emoji → utf8 column ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS src;
  DROP TABLE IF EXISTS t;
  CREATE TABLE src (
    id INT PRIMARY KEY,
    doc JSON
  );
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  INSERT INTO src VALUES (1, JSON_OBJECT('addr', 'ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ'));
  INSERT INTO t (val) SELECT JSON_UNQUOTE(JSON_EXTRACT(doc, '\$.addr')) FROM src;
" 2>/dev/null
check_result 24 "JSON_EXTRACT emoji into VARCHAR(10) utf8" 10
echo ""

# ===========================================================================
# Edge-case scenarios — real-world consequences of the bypass (E25-E30)
# ===========================================================================
echo "--- Edge-case scenarios (E25-E30) ---"
echo ""

# ---------------------------------------------------------------------------
# E25: Extreme length — how far can the bypass go?
# Is there any upper bound on oversized data stored via this path?
# ---------------------------------------------------------------------------
echo "--- E25: Extreme length REPEAT('A📝', 5000) into VARCHAR(10) ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES (REPEAT('A📝', 5000));
" 2>/dev/null
char_len_e25=$(mysql_cmd -N phase9_test -e "SELECT MAX(CHAR_LENGTH(val)) FROM t;" 2>/dev/null)
byte_len_e25=$(mysql_cmd -N phase9_test -e "SELECT MAX(LENGTH(val)) FROM t;" 2>/dev/null)
if [ -z "$char_len_e25" ] || [ "$char_len_e25" = "NULL" ]; then
  printf "  E%-2s %-58s -> char_len=NULL\n" "25" "Extreme length REPEAT('A📝', 5000)"
  PASS=$((PASS + 1))
elif [ "$char_len_e25" -le 10 ]; then
  printf "  E%-2s %-58s -> char_len=%-3s (CORRECT)\n" "25" "Extreme length REPEAT('A📝', 5000)" "$char_len_e25"
  PASS=$((PASS + 1))
else
  printf "  E%-2s %-58s -> char_len=%-5s byte_len=%-5s (BUG! limit=10)\n" "25" "Extreme length REPEAT('A📝', 5000)" "$char_len_e25" "$byte_len_e25"
  BUG=$((BUG + 1))
fi
echo ""

# ---------------------------------------------------------------------------
# E26: Secondary index on oversized column
# Does an indexed VARCHAR(10) with oversized data cause index issues?
# Can we SELECT via the index?
# ---------------------------------------------------------------------------
echo "--- E26: Secondary index on oversized column ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL,
    INDEX idx_val (val)
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');
" 2>/dev/null
check_result 26 "Secondary index on oversized VARCHAR(10)" 10

# Check if index-based SELECT works
idx_result=$(mysql_cmd -N phase9_test -e "SELECT CHAR_LENGTH(val) FROM t USE INDEX (idx_val) WHERE val IS NOT NULL;" 2>/dev/null || echo "ERROR")
printf "       Index SELECT result: char_len=%s\n" "$idx_result"
echo ""

# ---------------------------------------------------------------------------
# E27: Unique index + two different oversized values
# Can two distinct oversized strings coexist under a unique constraint?
# ---------------------------------------------------------------------------
echo "--- E27: Unique index + two different oversized values ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL,
    UNIQUE INDEX uq_val (val)
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES ('AAAAA📝BBBBB📓CCCCC');
  INSERT INTO t (val) VALUES ('XXXXX📝YYYYY📓ZZZZZ');
" 2>/dev/null
row_count=$(mysql_cmd -N phase9_test -e "SELECT COUNT(*) FROM t;" 2>/dev/null)
max_len=$(mysql_cmd -N phase9_test -e "SELECT MAX(CHAR_LENGTH(val)) FROM t;" 2>/dev/null)
if [ -n "$max_len" ] && [ "$max_len" -gt 10 ]; then
  printf "  E%-2s %-58s -> rows=%s max_char_len=%s (BUG!)\n" "27" "Unique index + two oversized values" "$row_count" "$max_len"
  BUG=$((BUG + 1))
else
  printf "  E%-2s %-58s -> rows=%s max_char_len=%s (CORRECT)\n" "27" "Unique index + two oversized values" "$row_count" "$max_len"
  PASS=$((PASS + 1))
fi
echo ""

# ---------------------------------------------------------------------------
# E28: ADMIN CHECK TABLE after oversized writes
# Does TiDB's own integrity checker detect the violation?
# ---------------------------------------------------------------------------
echo "--- E28: ADMIN CHECK TABLE after oversized writes ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL,
    INDEX idx_val (val)
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');
  INSERT INTO t (val) VALUES ('SHORT📝OK📓END');
" 2>/dev/null
admin_result=$(mysql_cmd phase9_test -e "ADMIN CHECK TABLE t;" 2>&1 || true)
if echo "$admin_result" | grep -qiE "ERROR|inconsist|corrupt"; then
  printf "  E%-2s %-58s -> DETECTED (integrity error)\n" "28" "ADMIN CHECK TABLE after oversized writes"
else
  printf "  E%-2s %-58s -> PASSED (no error detected)\n" "28" "ADMIN CHECK TABLE after oversized writes"
fi
# Not a pass/bug counter — this is a diagnostic test
echo ""

# ---------------------------------------------------------------------------
# E29: SELECT with WHERE on oversized column
# Can the oversized data be queried/filtered normally?
# ---------------------------------------------------------------------------
echo "--- E29: SELECT with WHERE on oversized column ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');
  INSERT INTO t (val) VALUES ('short');
" 2>/dev/null

# Test various WHERE conditions on oversized data
where_gt10=$(mysql_cmd -N phase9_test -e "SELECT COUNT(*) FROM t WHERE CHAR_LENGTH(val) > 10;" 2>/dev/null)
where_like=$(mysql_cmd -N phase9_test -e "SELECT COUNT(*) FROM t WHERE val LIKE 'ABCDE%';" 2>/dev/null)
where_eq=$(mysql_cmd -N phase9_test -e "SELECT COUNT(*) FROM t WHERE val = 'ABCDE?FGHIJ?KLMNO?PQRST?UVWXYZ';" 2>/dev/null)
check_result 29 "SELECT WHERE on oversized column" 10
printf "       WHERE CHAR_LENGTH>10: %s rows | WHERE LIKE: %s rows | WHERE = mangled: %s rows\n" \
  "$where_gt10" "$where_like" "$where_eq"
echo ""

# ---------------------------------------------------------------------------
# E30: ALTER TABLE MODIFY COLUMN after oversized writes
# What happens when you shrink the column after storing oversized data?
# ---------------------------------------------------------------------------
echo "--- E30: ALTER TABLE MODIFY COLUMN after oversized writes ---"
mysql_cmd phase9_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    val VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  INSERT INTO t (val) VALUES ('ABCDE📝FGHIJ📓KLMNO🖍PQRST📝UVWXYZ');
" 2>/dev/null

pre_len=$(mysql_cmd -N phase9_test -e "SELECT CHAR_LENGTH(val) FROM t WHERE id = 1;" 2>/dev/null)
alter_result=$(mysql_cmd phase9_test -e "ALTER TABLE t MODIFY COLUMN val VARCHAR(5) COLLATE utf8_general_ci DEFAULT NULL;" 2>&1 || true)

if echo "$alter_result" | grep -qiE "ERROR|1406|Data too long"; then
  printf "  E%-2s %-58s -> ALTER rejected (ERROR)\n" "30" "MODIFY COLUMN VARCHAR(10)→(5) after oversized"
  printf "       Pre-ALTER char_len=%s | ALTER blocked by oversized data\n" "$pre_len"
else
  post_len=$(mysql_cmd -N phase9_test -e "SELECT CHAR_LENGTH(val) FROM t WHERE id = 1;" 2>/dev/null)
  printf "  E%-2s %-58s -> ALTER accepted\n" "30" "MODIFY COLUMN VARCHAR(10)→(5) after oversized"
  printf "       Pre-ALTER char_len=%s | Post-ALTER char_len=%s\n" "$pre_len" "$post_len"
fi
echo ""

# ---------------------------------------------------------------------------
# Cleanup & Summary
# ---------------------------------------------------------------------------
mysql_cmd -e "SET GLOBAL sql_mode = '$STRICT';"
mysql_cmd -e "SET GLOBAL tidb_check_mb4_value_in_utf8 = ON;" 2>/dev/null
mysql_cmd -e "SET GLOBAL tidb_skip_utf8_check = OFF;" 2>/dev/null
mysql_cmd -e "DROP DATABASE IF EXISTS phase9_test;"

echo "=== Phase 9 Summary ==="
echo "  Correct (truncated or errored): $PASS"
echo "  BUG (exceeded VARCHAR limit):   $BUG"
echo "  Total: $((PASS + BUG))"
echo ""
if [ "$BUG" -gt 0 ]; then
  echo "  *** BYPASS CONFIRMED ***"
  echo "  utf8mb4 chars into utf8 column bypasses VARCHAR truncation"
  echo "  Root cause: Warning 1366 code path short-circuits length enforcement"
else
  echo "  No bypasses detected in this run."
fi
