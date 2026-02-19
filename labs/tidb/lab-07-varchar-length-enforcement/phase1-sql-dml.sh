#!/usr/bin/env bash
# Phase 1: SQL Layer DML Tests — 16 paths for VARCHAR enforcement
# Prereq: tiup playground v8.5.1 running on $TIDB_PORT
set -euo pipefail

TIDB_PORT="${TIDB_PORT:-4000}"
NONSTRICT="ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES"
STRICT="ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION"

mysql_cmd() { mysql --host 127.0.0.1 --port "$TIDB_PORT" -u root "$@"; }

echo "=== Phase 1: SQL Layer DML Tests ==="
mysql_cmd -e "CREATE DATABASE IF NOT EXISTS phase1_test;"
mysql_cmd -e "SET GLOBAL sql_mode = '$NONSTRICT';"

# Helper: create fresh table + run test + report char_len
run_test() {
  local num="$1" desc="$2" sql="$3"
  mysql_cmd phase1_test -e "
    DROP TABLE IF EXISTS t;
    CREATE TABLE t (
      id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
      nome VARCHAR(120) COLLATE utf8_general_ci DEFAULT NULL
    );
    $sql
  " 2>&1
  local char_len
  char_len=$(mysql_cmd -N phase1_test -e "SELECT MAX(CHAR_LENGTH(nome)) FROM t;" 2>/dev/null)
  printf "  #%-2s %-42s → char_len=%s\n" "$num" "$desc" "$char_len"
}

# Test 1: INSERT (text protocol)
run_test 1 "INSERT (text protocol)" "
  INSERT INTO t (nome) VALUES (REPEAT('A', 500));
"

# Test 2: INSERT at limit
run_test 2 "INSERT at limit (120 chars)" "
  INSERT INTO t (nome) VALUES (REPEAT('A', 120));
"

# Test 3: INSERT multi-byte
run_test 3 "INSERT multi-byte (REPEAT('ã', 200))" "
  INSERT INTO t (nome) VALUES (REPEAT('ã', 200));
"

# Test 4: UPDATE
run_test 4 "UPDATE to oversized value" "
  INSERT INTO t (nome) VALUES ('short');
  UPDATE t SET nome = REPEAT('U', 500) WHERE id = 1;
"

# Test 5: ON DUPLICATE KEY UPDATE
run_test 5 "ON DUPLICATE KEY UPDATE" "
  INSERT INTO t (id, nome) VALUES (1, 'short');
  INSERT INTO t (id, nome) VALUES (1, REPEAT('Z', 500))
    ON DUPLICATE KEY UPDATE nome = VALUES(nome);
"

# Test 6: INSERT ... SELECT
run_test 6 "INSERT ... SELECT from TEXT col" "
  DROP TABLE IF EXISTS src;
  CREATE TABLE src (data TEXT);
  INSERT INTO src VALUES (REPEAT('S', 500));
  INSERT INTO t (nome) SELECT data FROM src;
"

# Test 7: LOAD DATA LOCAL INFILE
TMPCSV=$(mktemp /tmp/phase1_XXXXXX.csv)
python3 -c "print('1,' + 'L' * 500)" > "$TMPCSV"
mysql_cmd phase1_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL PRIMARY KEY,
    nome VARCHAR(120) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET GLOBAL local_infile = 1;
" 2>/dev/null
mysql_cmd --local-infile=1 phase1_test -e "
  LOAD DATA LOCAL INFILE '$TMPCSV' INTO TABLE t
  FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' (id, nome);
" 2>/dev/null
char_len=$(mysql_cmd -N phase1_test -e "SELECT MAX(CHAR_LENGTH(nome)) FROM t;" 2>/dev/null)
printf "  #%-2s %-42s → char_len=%s\n" "7" "LOAD DATA LOCAL INFILE" "$char_len"
rm -f "$TMPCSV"

# Test 8: REPLACE INTO
run_test 8 "REPLACE INTO" "
  INSERT INTO t (id, nome) VALUES (1, 'short');
  REPLACE INTO t (id, nome) VALUES (1, REPEAT('R', 500));
"

# Test 9: SET NAMES latin1
mysql_cmd phase1_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    nome VARCHAR(120) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES latin1;
  INSERT INTO t (nome) VALUES (REPEAT('K', 500));
" 2>/dev/null
char_len=$(mysql_cmd -N phase1_test -e "SELECT MAX(CHAR_LENGTH(nome)) FROM t;" 2>/dev/null)
printf "  #%-2s %-42s → char_len=%s\n" "9" "SET NAMES latin1 → utf8 column" "$char_len"

# Test 10: SET NAMES utf8mb4
mysql_cmd phase1_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    nome VARCHAR(120) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET NAMES utf8mb4;
  INSERT INTO t (nome) VALUES (REPEAT('J', 500));
" 2>/dev/null
char_len=$(mysql_cmd -N phase1_test -e "SELECT MAX(CHAR_LENGTH(nome)) FROM t;" 2>/dev/null)
printf "  #%-2s %-42s → char_len=%s\n" "10" "SET NAMES utf8mb4 → utf8 column" "$char_len"

# Test 11: sql_mode = '' (empty)
mysql_cmd phase1_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    nome VARCHAR(120) COLLATE utf8_general_ci DEFAULT NULL
  );
  SET SESSION sql_mode = '';
  INSERT INTO t (nome) VALUES (REPEAT('E', 500));
" 2>/dev/null
char_len=$(mysql_cmd -N phase1_test -e "SELECT MAX(CHAR_LENGTH(nome)) FROM t;" 2>/dev/null)
printf "  #%-2s %-42s → char_len=%s\n" "11" "sql_mode = '' (empty)" "$char_len"

# Test 12: GLOBAL sql_mode (new connection inherits)
run_test 12 "GLOBAL sql_mode (new connection)" "
  INSERT INTO t (nome) VALUES (REPEAT('G', 500));
"

# Test 13: Prepared statement (pymysql binary protocol)
uv run --with pymysql python3 -c "
import pymysql
conn = pymysql.connect(host='127.0.0.1', port=$TIDB_PORT, user='root', database='phase1_test')
c = conn.cursor()
c.execute('DROP TABLE IF EXISTS t')
c.execute('CREATE TABLE t (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, nome VARCHAR(120) COLLATE utf8_general_ci DEFAULT NULL)')
c.execute('INSERT INTO t (nome) VALUES (%s)', ('P' * 500,))
conn.commit()
c.execute('SELECT MAX(CHAR_LENGTH(nome)) FROM t')
print(f'  #13 Prepared stmt (pymysql binary)            → char_len={c.fetchone()[0]}')
conn.close()
" 2>/dev/null

# Test 14: Batch executemany (pymysql)
uv run --with pymysql python3 -c "
import pymysql
conn = pymysql.connect(host='127.0.0.1', port=$TIDB_PORT, user='root', database='phase1_test')
c = conn.cursor()
c.execute('DROP TABLE IF EXISTS t')
c.execute('CREATE TABLE t (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, nome VARCHAR(120) COLLATE utf8_general_ci DEFAULT NULL)')
c.executemany('INSERT INTO t (nome) VALUES (%s)', [('B' * 500,), ('B' * 300,)])
conn.commit()
c.execute('SELECT MAX(CHAR_LENGTH(nome)) FROM t')
print(f'  #14 Batch executemany (pymysql)               → char_len={c.fetchone()[0]}')
conn.close()
" 2>/dev/null

# Test 15: ALTER TABLE shrink 500→120 (multi-row, with truncation verification)
mysql_cmd phase1_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    nome VARCHAR(500) COLLATE utf8_general_ci DEFAULT NULL
  );
  INSERT INTO t (nome) VALUES
    (REPEAT('A', 500)),
    (REPEAT('B', 300)),
    ('short'),
    (REPEAT('C', 120));
  ALTER TABLE t MODIFY COLUMN nome VARCHAR(120) COLLATE utf8_general_ci DEFAULT NULL;
" 2>/dev/null
char_len=$(mysql_cmd -N phase1_test -e "SELECT MAX(CHAR_LENGTH(nome)) FROM t;" 2>/dev/null)
printf "  #%-2s %-42s → char_len=%s\n" "15" "ALTER TABLE shrink 500→120" "$char_len"
# Verify data is physically truncated, not just displayed as 120
mysql_cmd -N phase1_test -e "
  SELECT id,
    CHAR_LENGTH(nome) AS char_len,
    CASE WHEN id=1 THEN nome = REPEAT('A', 120)
         WHEN id=2 THEN nome = REPEAT('B', 120)
         WHEN id=3 THEN nome = 'short'
         WHEN id=4 THEN nome = REPEAT('C', 120)
    END AS is_truncated_to_120
  FROM t ORDER BY id;
" 2>/dev/null | while read -r id clen trunc; do
  printf "       id=%s char_len=%-3s physically_truncated=%s\n" "$id" "$clen" "$trunc"
done

# Test 16: Real-world Portuguese text
run_test 16 "Real-world Portuguese text (314ch)" "
  INSERT INTO t (nome) VALUES (CONCAT(
    'Dourados MS Cotação: 956809 Samuel R\$ 300 ',
    'Transportadora Andorinha Prazo de 7 dias ',
    'úteis Obs colocar o número da cotação na ',
    'nota fiscal ou mandar um bilhete escrito ',
    'com as informações acima Frete a cobrar ',
    REPEAT('dados extras ', 10)
  ));
"

# Reset
mysql_cmd -e "SET GLOBAL sql_mode = '$STRICT';"
echo "=== Phase 1 complete ==="
