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

# ---------------------------------------------------------------------------
# Cleanup & Summary
# ---------------------------------------------------------------------------
mysql_cmd -e "SET GLOBAL sql_mode = '$STRICT';"
mysql_cmd -e "DROP DATABASE IF EXISTS phase9_test;"

echo "=== Phase 9 Summary ==="
echo "  Correct (truncated or errored): $PASS"
echo "  BUG (exceeded VARCHAR limit):   $BUG"
echo "  Total: $((PASS + BUG))"
echo ""
if [ "$BUG" -gt 0 ]; then
  echo "  *** BYPASS CONFIRMED ***"
  echo "  utf8mb4 chars into utf8 column bypasses VARCHAR truncation"
  echo "  Root cause: Warning 1366 code path skips length enforcement"
else
  echo "  No bypasses detected in this run."
fi
