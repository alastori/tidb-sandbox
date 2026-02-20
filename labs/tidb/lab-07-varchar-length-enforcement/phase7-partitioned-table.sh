#!/usr/bin/env bash
# Phase 7: Partitioned Table Reproduction
# Tests the UNTESTED variable from Bling's production: PARTITION BY KEY + composite PK
#
# Background: All 91 tests in Phases 1-6 used non-partitioned tables with simple PKs.
# Bling's `gnre` table uses PARTITION BY KEY(idEmpresa) PARTITIONS 128,
# composite PK (id, idEmpresa), AUTO_ID_CACHE=1, and utf8 charset with
# utf8mb4 connection charset. Column `enderecoDestinatario` is VARCHAR(70) NOT NULL
# and stores 141 chars (2x limit). DDL history confirms no schema change on that column.
#
# Prereq: tiup playground v8.5.1 running on $TIDB_PORT
set -euo pipefail

TIDB_PORT="${TIDB_PORT:-4000}"
NONSTRICT="ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES"

mysql_cmd() { mysql --host 127.0.0.1 --port "$TIDB_PORT" -u root "$@"; }

echo "=== Phase 7: Partitioned Table Reproduction ==="
echo "    Target: gnre.enderecoDestinatario VARCHAR(70) storing 141 chars"
echo ""

mysql_cmd -e "DROP DATABASE IF EXISTS phase7_test; CREATE DATABASE phase7_test DEFAULT CHARSET utf8 COLLATE utf8_general_ci;"
mysql_cmd -e "SET GLOBAL sql_mode = '$NONSTRICT';"

# ---------------------------------------------------------------------------
# Helper: create gnre-like partitioned table, run SQL, check char_len
# Uses VARCHAR(70) NOT NULL to match enderecoDestinatario exactly
# ---------------------------------------------------------------------------
run_part() {
  local num="$1" desc="$2" setup="$3" sql="$4"
  mysql_cmd phase7_test -e "
    DROP TABLE IF EXISTS t;
    CREATE TABLE t (
      id BIGINT NOT NULL AUTO_INCREMENT,
      idEmpresa BIGINT NOT NULL,
      enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
      PRIMARY KEY (id, idEmpresa) /*T![clustered_index] CLUSTERED */
    ) AUTO_ID_CACHE 1
    PARTITION BY KEY (idEmpresa) PARTITIONS 128;
    $setup
    $sql
  " 2>&1
  local char_len
  char_len=$(mysql_cmd -N phase7_test -e "SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) FROM t;" 2>/dev/null)
  printf "  P%-2s %-58s → char_len=%s\n" "$num" "$desc" "$char_len"
}

# Helper: same but with DEFAULT NULL (to compare NOT NULL vs nullable)
run_part_nullable() {
  local num="$1" desc="$2" setup="$3" sql="$4"
  mysql_cmd phase7_test -e "
    DROP TABLE IF EXISTS t;
    CREATE TABLE t (
      id BIGINT NOT NULL AUTO_INCREMENT,
      idEmpresa BIGINT NOT NULL,
      nome VARCHAR(70) COLLATE utf8_general_ci DEFAULT NULL,
      PRIMARY KEY (id, idEmpresa) /*T![clustered_index] CLUSTERED */
    ) AUTO_ID_CACHE 1
    PARTITION BY KEY (idEmpresa) PARTITIONS 128;
    $setup
    $sql
  " 2>&1
  local char_len
  char_len=$(mysql_cmd -N phase7_test -e "SELECT MAX(CHAR_LENGTH(nome)) FROM t;" 2>/dev/null)
  printf "  P%-2s %-58s → char_len=%s\n" "$num" "$desc" "$char_len"
}

echo "--- Section A: Exact gnre schema (PARTITION BY KEY, composite PK, NOT NULL) ---"
echo ""

# P1: Basic INSERT with REPEAT
run_part 1 "INSERT REPEAT('A', 200) — partitioned, NOT NULL" \
  "" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('A', 200));"

# P2: INSERT with SET NAMES utf8mb4 (matching charset mismatch)
run_part 2 "SET NAMES utf8mb4 → utf8 partitioned table" \
  "SET NAMES utf8mb4;" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('A', 200));"

# P3: INSERT with exact charset config from production
run_part 3 "Exact charset config (utf8mb4 client+conn, utf8 table)" \
  "SET character_set_client = utf8mb4;
   SET character_set_connection = utf8mb4;
   SET character_set_results = utf8mb4;
   SET collation_connection = utf8mb4_general_ci;" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('A', 200));"

# P4: INSERT real-world address data (like the actual stored values)
run_part 4 "Real address data (141 chars, like row 45147206)" \
  "SET NAMES utf8mb4;" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345,
    'Avenida Valerio Osmar Estevao Loja Agro Infinity Aberto Da, 77, Avenida Valerio Osmar Estevao Loja Agro Infinity Aberto Da, Nao informado extra padding');"

# P5: UPDATE to oversized value
run_part 5 "UPDATE to oversized value — partitioned" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, 'short');" \
  "UPDATE t SET enderecoDestinatario = REPEAT('U', 200) WHERE idEmpresa = 12345;"

# P6: INSERT ... SELECT from TEXT column
run_part 6 "INSERT...SELECT from TEXT — partitioned" \
  "DROP TABLE IF EXISTS src;
   CREATE TABLE src (empresa BIGINT, data TEXT);
   INSERT INTO src VALUES (12345, REPEAT('S', 200));" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) SELECT empresa, data FROM src;"

# P7: REPLACE INTO
run_part 7 "REPLACE INTO — partitioned" \
  "INSERT INTO t (id, idEmpresa, enderecoDestinatario) VALUES (1, 12345, 'short');" \
  "REPLACE INTO t (id, idEmpresa, enderecoDestinatario) VALUES (1, 12345, REPEAT('R', 200));"

# P8: ON DUPLICATE KEY UPDATE
run_part 8 "ON DUPLICATE KEY UPDATE — partitioned" \
  "INSERT INTO t (id, idEmpresa, enderecoDestinatario) VALUES (1, 12345, 'short');" \
  "INSERT INTO t (id, idEmpresa, enderecoDestinatario) VALUES (1, 12345, REPEAT('D', 200))
     ON DUPLICATE KEY UPDATE enderecoDestinatario = VALUES(enderecoDestinatario);"

# P9: Multi-row INSERT across different partitions
run_part 9 "Multi-row INSERT across partitions (5 empresas)" \
  "" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES
     (100, REPEAT('A', 200)),
     (200, REPEAT('B', 200)),
     (300, REPEAT('C', 200)),
     (400, REPEAT('D', 200)),
     (500, REPEAT('E', 200));"

# P10: INSERT IGNORE — partitioned
run_part 10 "INSERT IGNORE — partitioned" \
  "" \
  "INSERT IGNORE INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('I', 200));"

echo ""
echo "--- Section B: System variables + partitioned table ---"
echo ""

# P11: skip_utf8_check + partitioned
run_part 11 "skip_utf8_check=ON — partitioned" \
  "SET SESSION tidb_skip_utf8_check = 1;" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('A', 200));"

# P12: skip_utf8_check + SET NAMES utf8mb4 + partitioned
run_part 12 "skip_utf8_check=ON + NAMES utf8mb4 — partitioned" \
  "SET SESSION tidb_skip_utf8_check = 1; SET NAMES utf8mb4;" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('A', 200));"

# P13: mutation_checker OFF + partitioned
run_part 13 "mutation_checker=OFF — partitioned" \
  "SET SESSION tidb_enable_mutation_checker = OFF;" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('A', 200));"

# P14: Combined: skip_utf8 + mutation OFF + utf8mb4 + partitioned
run_part 14 "skip_utf8+mutation OFF+utf8mb4 — partitioned" \
  "SET SESSION tidb_skip_utf8_check = 1;
   SET SESSION tidb_enable_mutation_checker = OFF;
   SET NAMES utf8mb4;" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('A', 200));"

# P15: batch_insert + partitioned
run_part 15 "batch_insert=ON + dml_batch=10 — partitioned" \
  "SET SESSION tidb_batch_insert = 1; SET SESSION tidb_dml_batch_size = 10;" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES
     (100, REPEAT('A', 200)),
     (200, REPEAT('B', 200)),
     (300, REPEAT('C', 200)),
     (400, REPEAT('D', 200)),
     (500, REPEAT('E', 200));"

# P16: opt_write_row_id + partitioned
run_part 16 "opt_write_row_id=ON — partitioned" \
  "SET SESSION tidb_opt_write_row_id = 1;" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('A', 200));"

# P17: check_mb4_value_in_utf8=OFF + utf8mb4 conn + partitioned
run_part 17 "check_mb4=OFF + utf8mb4 — partitioned" \
  "SET SESSION tidb_check_mb4_value_in_utf8 = OFF; SET NAMES utf8mb4;" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('A', 200));"

# P18: Server-side PREPARE/EXECUTE + partitioned
mysql_cmd phase7_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT,
    idEmpresa BIGINT NOT NULL,
    enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
    PRIMARY KEY (id, idEmpresa)
  ) AUTO_ID_CACHE 1
  PARTITION BY KEY (idEmpresa) PARTITIONS 128;
  SET NAMES utf8mb4;
  PREPARE stmt FROM 'INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (?, ?)';
  SET @emp = 12345;
  SET @val = REPEAT('A', 200);
  EXECUTE stmt USING @emp, @val;
  DEALLOCATE PREPARE stmt;
" 2>&1
char_len=$(mysql_cmd -N phase7_test -e "SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) FROM t;" 2>/dev/null)
printf "  P%-2s %-58s → char_len=%s\n" "18" "PREPARE/EXECUTE + utf8mb4 — partitioned" "$char_len"

# P19: Pessimistic txn + constraint_check OFF + partitioned
mysql_cmd phase7_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT,
    idEmpresa BIGINT NOT NULL,
    enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
    PRIMARY KEY (id, idEmpresa)
  ) AUTO_ID_CACHE 1
  PARTITION BY KEY (idEmpresa) PARTITIONS 128;
  SET NAMES utf8mb4;
  SET SESSION tidb_constraint_check_in_place_pessimistic = OFF;
  SET SESSION tidb_txn_mode = 'pessimistic';
  BEGIN;
  INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('A', 200));
  COMMIT;
" 2>&1
char_len=$(mysql_cmd -N phase7_test -e "SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) FROM t;" 2>/dev/null)
printf "  P%-2s %-58s → char_len=%s\n" "19" "pessimistic + constraint OFF — partitioned" "$char_len"

# P20: Optimistic txn + partitioned
mysql_cmd phase7_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT,
    idEmpresa BIGINT NOT NULL,
    enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
    PRIMARY KEY (id, idEmpresa)
  ) AUTO_ID_CACHE 1
  PARTITION BY KEY (idEmpresa) PARTITIONS 128;
  SET NAMES utf8mb4;
  SET SESSION tidb_txn_mode = 'optimistic';
  BEGIN;
  INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('A', 200));
  COMMIT;
" 2>&1
char_len=$(mysql_cmd -N phase7_test -e "SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) FROM t;" 2>/dev/null)
printf "  P%-2s %-58s → char_len=%s\n" "20" "optimistic txn — partitioned" "$char_len"

echo ""
echo "--- Section C: Concurrency + partitioned table ---"
echo ""

# P21: 20 concurrent INSERTs to different partitions
echo "  P21: Running 20 concurrent INSERTs across partitions..."
mysql_cmd phase7_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT,
    idEmpresa BIGINT NOT NULL,
    enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
    PRIMARY KEY (id, idEmpresa)
  ) AUTO_ID_CACHE 1
  PARTITION BY KEY (idEmpresa) PARTITIONS 128;
"
for i in $(seq 1 20); do
  mysql_cmd phase7_test -e "
    SET NAMES utf8mb4;
    INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES ($((i * 1000)), REPEAT('T', 200));
  " 2>/dev/null &
done
wait
result=$(mysql_cmd -N phase7_test -e "
  SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) AS max_len,
         COUNT(*) AS total,
         SUM(CASE WHEN CHAR_LENGTH(enderecoDestinatario) > 70 THEN 1 ELSE 0 END) AS overflow
  FROM t;" 2>/dev/null)
printf "  P%-2s %-58s → %s\n" "21" "20 concurrent INSERTs across partitions" "$result"

# P22: Concurrent DDL + INSERTs on partitioned table
echo "  P22: Running concurrent DDL + 50 INSERTs on partitioned table..."
mysql_cmd phase7_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT,
    idEmpresa BIGINT NOT NULL,
    enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
    PRIMARY KEY (id, idEmpresa)
  ) AUTO_ID_CACHE 1
  PARTITION BY KEY (idEmpresa) PARTITIONS 128;
"
for i in $(seq 1 50); do
  mysql_cmd phase7_test -e "
    SET NAMES utf8mb4;
    INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES ($((i * 100)), REPEAT('R', 200));
  " 2>/dev/null &
done
mysql_cmd phase7_test -e "ALTER TABLE t ADD INDEX idx_end (enderecoDestinatario(30));" 2>/dev/null &
wait
result=$(mysql_cmd -N phase7_test -e "
  SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) AS max_len,
         COUNT(*) AS total,
         SUM(CASE WHEN CHAR_LENGTH(enderecoDestinatario) > 70 THEN 1 ELSE 0 END) AS overflow
  FROM t;" 2>/dev/null)
printf "  P%-2s %-58s → %s\n" "22" "Concurrent DDL + 50 INSERTs — partitioned" "$result"

echo ""
echo "--- Section D: Protocol paths + partitioned table ---"
echo ""

# P23: pymysql binary protocol + partitioned
uv run --with pymysql python3 -c "
import pymysql
conn = pymysql.connect(host='127.0.0.1', port=$TIDB_PORT, user='root', database='phase7_test',
                       charset='utf8mb4')
c = conn.cursor()
c.execute('DROP TABLE IF EXISTS t')
c.execute('''CREATE TABLE t (
  id BIGINT NOT NULL AUTO_INCREMENT,
  idEmpresa BIGINT NOT NULL,
  enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
  PRIMARY KEY (id, idEmpresa)
) AUTO_ID_CACHE 1 PARTITION BY KEY (idEmpresa) PARTITIONS 128''')
c.execute('INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (%s, %s)', (12345, 'A' * 200))
conn.commit()
c.execute('SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) FROM t')
print(f'  P23 pymysql binary (charset=utf8mb4) — partitioned      → char_len={c.fetchone()[0]}')
conn.close()
" 2>/dev/null

# P24: pymysql executemany + partitioned (multiple partitions)
uv run --with pymysql python3 -c "
import pymysql
conn = pymysql.connect(host='127.0.0.1', port=$TIDB_PORT, user='root', database='phase7_test',
                       charset='utf8mb4')
c = conn.cursor()
c.execute('DROP TABLE IF EXISTS t')
c.execute('''CREATE TABLE t (
  id BIGINT NOT NULL AUTO_INCREMENT,
  idEmpresa BIGINT NOT NULL,
  enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
  PRIMARY KEY (id, idEmpresa)
) AUTO_ID_CACHE 1 PARTITION BY KEY (idEmpresa) PARTITIONS 128''')
rows = [(i * 1000, 'A' * 200) for i in range(1, 51)]
c.executemany('INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (%s, %s)', rows)
conn.commit()
c.execute('SELECT MAX(CHAR_LENGTH(enderecoDestinatario)), COUNT(*), SUM(CASE WHEN CHAR_LENGTH(enderecoDestinatario) > 70 THEN 1 ELSE 0 END) FROM t')
row = c.fetchone()
print(f'  P24 pymysql executemany 50 rows — partitioned           → max={row[0]}, total={row[1]}, overflow={row[2]}')
conn.close()
" 2>/dev/null

# P25: mysql-connector-python C extension + partitioned
uv run --with mysql-connector-python python3 -c "
import mysql.connector
conn = mysql.connector.connect(
    host='127.0.0.1', port=$TIDB_PORT, user='root', database='phase7_test',
    charset='utf8mb4', use_pure=False
)
c = conn.cursor(prepared=True)
c.execute('DROP TABLE IF EXISTS t')
c.execute('''CREATE TABLE t (
  id BIGINT NOT NULL AUTO_INCREMENT,
  idEmpresa BIGINT NOT NULL,
  enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
  PRIMARY KEY (id, idEmpresa)
) AUTO_ID_CACHE 1 PARTITION BY KEY (idEmpresa) PARTITIONS 128''')
c.execute('INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (%s, %s)', (12345, 'A' * 200))
conn.commit()
c.execute('SELECT CHAR_LENGTH(enderecoDestinatario) FROM t')
print(f'  P25 mysql-connector-python C ext — partitioned          → char_len={c.fetchone()[0]}')
conn.close()
" 2>/dev/null

echo ""
echo "--- Section E: LOAD DATA + partitioned table ---"
echo ""

# P26: LOAD DATA LOCAL INFILE + partitioned
TMPCSV=$(mktemp /tmp/phase7_XXXXXX.csv)
python3 -c "
for i in range(1, 101):
    emp = i * 100
    print(f'{emp},{\"L\" * 200}')
" > "$TMPCSV"
mysql_cmd phase7_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    idEmpresa BIGINT NOT NULL,
    enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
    PRIMARY KEY (idEmpresa)
  ) PARTITION BY KEY (idEmpresa) PARTITIONS 128;
  SET GLOBAL local_infile = 1;
" 2>/dev/null
mysql_cmd --local-infile=1 phase7_test -e "
  SET NAMES utf8mb4;
  LOAD DATA LOCAL INFILE '$TMPCSV' INTO TABLE t
  FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' (idEmpresa, enderecoDestinatario);
" 2>/dev/null
result=$(mysql_cmd -N phase7_test -e "
  SELECT MAX(CHAR_LENGTH(enderecoDestinatario)), COUNT(*),
         SUM(CASE WHEN CHAR_LENGTH(enderecoDestinatario) > 70 THEN 1 ELSE 0 END) FROM t;
" 2>/dev/null)
printf "  P%-2s %-58s → %s\n" "26" "LOAD DATA LOCAL 100 rows — partitioned" "$result"
rm -f "$TMPCSV"

echo ""
echo "--- Section F: Expression edge cases + partitioned table ---"
echo ""

# P27: JSON_EXTRACT → partitioned VARCHAR(70)
mysql_cmd phase7_test -e "
  DROP TABLE IF EXISTS jsrc;
  DROP TABLE IF EXISTS t;
  CREATE TABLE jsrc (doc JSON);
  INSERT INTO jsrc VALUES (JSON_OBJECT('addr', REPEAT('A', 200)));
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT,
    idEmpresa BIGINT NOT NULL,
    enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
    PRIMARY KEY (id, idEmpresa)
  ) AUTO_ID_CACHE 1
  PARTITION BY KEY (idEmpresa) PARTITIONS 128;
  SET NAMES utf8mb4;
  INSERT INTO t (idEmpresa, enderecoDestinatario)
    SELECT 12345, JSON_UNQUOTE(JSON_EXTRACT(doc, '\$.addr')) FROM jsrc;
" 2>&1
char_len=$(mysql_cmd -N phase7_test -e "SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) FROM t;" 2>/dev/null)
printf "  P%-2s %-58s → char_len=%s\n" "27" "JSON_EXTRACT → partitioned VARCHAR(70)" "$char_len"

# P28: GROUP_CONCAT → partitioned VARCHAR(70)
mysql_cmd phase7_test -e "
  DROP TABLE IF EXISTS src;
  DROP TABLE IF EXISTS t;
  CREATE TABLE src (empresa BIGINT, val VARCHAR(50));
  INSERT INTO src VALUES
    (12345, REPEAT('a', 50)), (12345, REPEAT('b', 50)),
    (12345, REPEAT('c', 50)), (12345, REPEAT('d', 50));
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT,
    idEmpresa BIGINT NOT NULL,
    enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
    PRIMARY KEY (id, idEmpresa)
  ) AUTO_ID_CACHE 1
  PARTITION BY KEY (idEmpresa) PARTITIONS 128;
  SET NAMES utf8mb4;
  SET SESSION group_concat_max_len = 10000;
  INSERT INTO t (idEmpresa, enderecoDestinatario)
    SELECT empresa, GROUP_CONCAT(val SEPARATOR '') FROM src GROUP BY empresa;
" 2>&1
char_len=$(mysql_cmd -N phase7_test -e "SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) FROM t;" 2>/dev/null)
printf "  P%-2s %-58s → char_len=%s\n" "28" "GROUP_CONCAT → partitioned VARCHAR(70)" "$char_len"

# P29: CONCAT multiple address fields (simulating app behavior)
run_part 29 "CONCAT address fields → partitioned VARCHAR(70)" \
  "SET NAMES utf8mb4;" \
  "INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345,
    CONCAT('Rua Bromelia 102 ', 'Casa n02 na parte de tras  ', 'Tijucas Santa Ca, 88201516, ', 'Casa n02 na parte de tras ., Universitario'));"

echo ""
echo "--- Section G: Nullable vs NOT NULL comparison + partitioned ---"
echo ""

# P30: Same test with DEFAULT NULL (lab-07 pattern)
run_part_nullable 30 "VARCHAR(70) DEFAULT NULL — partitioned" \
  "SET NAMES utf8mb4;" \
  "INSERT INTO t (idEmpresa, nome) VALUES (12345, REPEAT('A', 200));"

# P31: VARCHAR(120) NOT NULL — partitioned (contato equivalent)
mysql_cmd phase7_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT,
    idEmpresa BIGINT NOT NULL,
    nome VARCHAR(120) COLLATE utf8_general_ci NOT NULL DEFAULT '',
    PRIMARY KEY (id, idEmpresa)
  ) AUTO_ID_CACHE 1
  PARTITION BY KEY (idEmpresa) PARTITIONS 128;
  SET NAMES utf8mb4;
  INSERT INTO t (idEmpresa, nome) VALUES (12345, REPEAT('A', 500));
" 2>&1
char_len=$(mysql_cmd -N phase7_test -e "SELECT MAX(CHAR_LENGTH(nome)) FROM t;" 2>/dev/null)
printf "  P%-2s %-58s → char_len=%s\n" "31" "VARCHAR(120) NOT NULL — partitioned (contato)" "$char_len"

echo ""
echo "--- Section H: Partition count variations ---"
echo ""

# P32: PARTITION BY KEY, 1 partition (degenerate case)
mysql_cmd phase7_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT,
    idEmpresa BIGINT NOT NULL,
    enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
    PRIMARY KEY (id, idEmpresa)
  ) AUTO_ID_CACHE 1
  PARTITION BY KEY (idEmpresa) PARTITIONS 1;
  SET NAMES utf8mb4;
  INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('A', 200));
" 2>&1
char_len=$(mysql_cmd -N phase7_test -e "SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) FROM t;" 2>/dev/null)
printf "  P%-2s %-58s → char_len=%s\n" "32" "PARTITION BY KEY, 1 partition" "$char_len"

# P33: PARTITION BY HASH (different partition strategy)
mysql_cmd phase7_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT,
    idEmpresa BIGINT NOT NULL,
    enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
    PRIMARY KEY (id, idEmpresa)
  ) AUTO_ID_CACHE 1
  PARTITION BY HASH (idEmpresa) PARTITIONS 128;
  SET NAMES utf8mb4;
  INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('A', 200));
" 2>&1
char_len=$(mysql_cmd -N phase7_test -e "SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) FROM t;" 2>/dev/null)
printf "  P%-2s %-58s → char_len=%s\n" "33" "PARTITION BY HASH, 128 partitions" "$char_len"

# P34: PARTITION BY RANGE (different partition strategy)
mysql_cmd phase7_test -e "
  DROP TABLE IF EXISTS t;
  CREATE TABLE t (
    id BIGINT NOT NULL AUTO_INCREMENT,
    idEmpresa BIGINT NOT NULL,
    enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
    PRIMARY KEY (id, idEmpresa)
  ) AUTO_ID_CACHE 1
  PARTITION BY RANGE (idEmpresa) (
    PARTITION p0 VALUES LESS THAN (10000),
    PARTITION p1 VALUES LESS THAN (20000),
    PARTITION p2 VALUES LESS THAN (MAXVALUE)
  );
  SET NAMES utf8mb4;
  INSERT INTO t (idEmpresa, enderecoDestinatario) VALUES (12345, REPEAT('A', 200));
" 2>&1
char_len=$(mysql_cmd -N phase7_test -e "SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) FROM t;" 2>/dev/null)
printf "  P%-2s %-58s → char_len=%s\n" "34" "PARTITION BY RANGE" "$char_len"

echo ""
echo "--- Section I: Full gnre schema replica ---"
echo ""

# P35: Full gnre schema (all columns, all indexes, placement policy excluded)
mysql_cmd phase7_test -e "
  DROP TABLE IF EXISTS gnre_replica;
  CREATE TABLE gnre_replica (
    id BIGINT NOT NULL AUTO_INCREMENT,
    idEmpresa BIGINT NOT NULL,
    c01_UfFavorecida CHAR(2) COLLATE utf8_general_ci NOT NULL,
    c02_receita VARCHAR(6) COLLATE utf8_general_ci NOT NULL,
    c26_produto INT NOT NULL,
    CNPJ VARCHAR(14) COLLATE utf8_general_ci NOT NULL,
    c28_tipoDocOrigem INT NOT NULL,
    c04_docOrigem VARCHAR(18) COLLATE utf8_general_ci NOT NULL,
    c10_valorTotal DECIMAL(15,2) NOT NULL,
    c14_dataVencimento DATE NOT NULL,
    c16_razaoSocialEmitente VARCHAR(100) COLLATE utf8_general_ci NOT NULL,
    c18_enderecoEmitente VARCHAR(100) COLLATE utf8_general_ci NOT NULL,
    c19_municipioEmitente VARCHAR(5) COLLATE utf8_general_ci NOT NULL,
    municipio VARCHAR(100) COLLATE utf8_general_ci NOT NULL,
    c20_ufEnderecoEmitente CHAR(2) COLLATE utf8_general_ci NOT NULL,
    c21_cepEmitente VARCHAR(8) COLLATE utf8_general_ci NOT NULL,
    c22_telefoneEmitente VARCHAR(11) COLLATE utf8_general_ci NOT NULL,
    c33_dataPagamento DATE NOT NULL,
    dataCriacao DATETIME NOT NULL,
    dataAlteracao DATETIME NOT NULL,
    chaveAcesso VARCHAR(44) COLLATE utf8_general_ci NOT NULL,
    idOrigem BIGINT NOT NULL,
    tipoOrigem VARCHAR(15) COLLATE utf8_general_ci NOT NULL,
    c37_razaoSocialDestinatario VARCHAR(60) COLLATE utf8_general_ci NOT NULL,
    c38_municipioDestinatario VARCHAR(5) COLLATE utf8_general_ci NOT NULL,
    municipioDestinatario VARCHAR(100) COLLATE utf8_general_ci NOT NULL,
    CNPJDestinatario VARCHAR(14) COLLATE utf8_general_ci NOT NULL,
    situacao TINYINT NOT NULL DEFAULT '1',
    valor_fcp DECIMAL(15,2) NOT NULL,
    protocolo VARCHAR(25) COLLATE utf8_general_ci NOT NULL,
    codigoBarras VARCHAR(48) COLLATE utf8_general_ci NOT NULL,
    numeroControle VARCHAR(25) COLLATE utf8_general_ci NOT NULL,
    idContato BIGINT NOT NULL,
    cepDestinatario VARCHAR(8) COLLATE utf8_general_ci NOT NULL,
    dataEmissaoDoc DATETIME NOT NULL,
    enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
    c15_convenio VARCHAR(30) COLLATE utf8_general_ci NOT NULL,
    c25_detalhamentoReceita VARCHAR(6) COLLATE utf8_general_ci NOT NULL,
    c36_inscricaoEstadualDestinatario VARCHAR(16) COLLATE utf8_general_ci NOT NULL DEFAULT '',
    excluido TINYINT NOT NULL DEFAULT '0',
    inscricaoEstadualEmitente VARCHAR(16) COLLATE utf8_general_ci NOT NULL DEFAULT '',
    PRIMARY KEY (id, idEmpresa) /*T![clustered_index] CLUSTERED */,
    KEY idContato (idContato),
    KEY idEmpresaExcluido (idEmpresa, excluido),
    KEY idEmpresaIdOrigemTipoOrigem (idEmpresa, idOrigem, tipoOrigem),
    KEY idEmpresaDataVencimento (idEmpresa, c14_dataVencimento)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci
  AUTO_ID_CACHE 1
  PARTITION BY KEY (idEmpresa) PARTITIONS 128;

  SET NAMES utf8mb4;
  INSERT INTO gnre_replica (
    idEmpresa, c01_UfFavorecida, c02_receita, c26_produto, CNPJ,
    c28_tipoDocOrigem, c04_docOrigem, c10_valorTotal, c14_dataVencimento,
    c16_razaoSocialEmitente, c18_enderecoEmitente, c19_municipioEmitente,
    municipio, c20_ufEnderecoEmitente, c21_cepEmitente, c22_telefoneEmitente,
    c33_dataPagamento, dataCriacao, dataAlteracao, chaveAcesso,
    idOrigem, tipoOrigem, c37_razaoSocialDestinatario, c38_municipioDestinatario,
    municipioDestinatario, CNPJDestinatario, valor_fcp, protocolo,
    codigoBarras, numeroControle, idContato, cepDestinatario, dataEmissaoDoc,
    enderecoDestinatario, c15_convenio, c25_detalhamentoReceita
  ) VALUES (
    12345, 'SP', '100236', 0, '12345678901234',
    10, '123456789012345678', 150.00, '2026-02-28',
    REPEAT('X', 100), REPEAT('Y', 100), '12345',
    REPEAT('Z', 100), 'SP', '12345678', '11987654321',
    '2026-02-20', NOW(), NOW(), REPEAT('K', 44),
    999, 'NF', REPEAT('D', 60), '54321',
    REPEAT('M', 100), '98765432101234', 10.00, REPEAT('P', 25),
    REPEAT('B', 48), REPEAT('N', 25), 1, '87654321', NOW(),
    REPEAT('A', 200),
    REPEAT('C', 30), '100236'
  );
" 2>&1
char_len=$(mysql_cmd -N phase7_test -e "SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) FROM gnre_replica;" 2>/dev/null)
printf "  P%-2s %-58s → char_len=%s\n" "35" "Full gnre schema replica — INSERT 200ch" "$char_len"

# P36: Full gnre schema + concurrent inserts from multiple "empresas"
echo "  P36: Full gnre schema + 20 concurrent inserts..."
for i in $(seq 1 20); do
  emp=$((i * 1000))
  mysql_cmd phase7_test -e "
    SET NAMES utf8mb4;
    INSERT INTO gnre_replica (
      idEmpresa, c01_UfFavorecida, c02_receita, c26_produto, CNPJ,
      c28_tipoDocOrigem, c04_docOrigem, c10_valorTotal, c14_dataVencimento,
      c16_razaoSocialEmitente, c18_enderecoEmitente, c19_municipioEmitente,
      municipio, c20_ufEnderecoEmitente, c21_cepEmitente, c22_telefoneEmitente,
      c33_dataPagamento, dataCriacao, dataAlteracao, chaveAcesso,
      idOrigem, tipoOrigem, c37_razaoSocialDestinatario, c38_municipioDestinatario,
      municipioDestinatario, CNPJDestinatario, valor_fcp, protocolo,
      codigoBarras, numeroControle, idContato, cepDestinatario, dataEmissaoDoc,
      enderecoDestinatario, c15_convenio, c25_detalhamentoReceita
    ) VALUES (
      $emp, 'SP', '100236', 0, '12345678901234',
      10, '123456789012345678', 150.00, '2026-02-28',
      'Emitente $i', 'Endereco $i', '12345',
      'Municipio $i', 'SP', '12345678', '11987654321',
      '2026-02-20', NOW(), NOW(), REPEAT('K', 44),
      $i, 'NF', 'Destinatario $i', '54321',
      'MunicDest $i', '98765432101234', 10.00, REPEAT('P', 25),
      REPEAT('B', 48), REPEAT('N', 25), $i, '87654321', NOW(),
      REPEAT('E', 200),
      REPEAT('C', 30), '100236'
    );
  " 2>/dev/null &
done
wait
result=$(mysql_cmd -N phase7_test -e "
  SELECT MAX(CHAR_LENGTH(enderecoDestinatario)) AS max_len,
         COUNT(*) AS total,
         SUM(CASE WHEN CHAR_LENGTH(enderecoDestinatario) > 70 THEN 1 ELSE 0 END) AS overflow
  FROM gnre_replica;" 2>/dev/null)
printf "  P%-2s %-58s → %s\n" "36" "Full gnre schema + 20 concurrent inserts" "$result"

echo ""
echo "=== Phase 7 Summary ==="
echo "Tested 36 hypotheses with partitioned tables:"
echo "  Section A: 10 DML paths on exact gnre schema (PARTITION BY KEY, composite PK)"
echo "  Section B: 10 system variable combinations + partitioned"
echo "  Section C: 2 concurrency tests on partitioned table"
echo "  Section D: 3 DB driver tests (pymysql, mysql-connector-python)"
echo "  Section E: 1 LOAD DATA test on partitioned table"
echo "  Section F: 3 expression edge cases + partitioned"
echo "  Section G: 3 nullable/size/partition comparisons"
echo "  Section H: 3 partition strategy variations (KEY, HASH, RANGE)"
echo "  Section I: 2 full gnre schema replica tests"
echo ""
echo "If all P1-P36 show char_len<=70: partitioned tables are NOT the cause."
echo "The root cause is environment-specific (driver, proxy, or TiDB build)."
echo "=== Phase 7 complete ==="
