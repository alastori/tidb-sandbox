#!/usr/bin/env bash
# Phase 2: Dumpling → IMPORT INTO round-trip
# Prereq: tiup playground v8.5.1 running on $TIDB_PORT
set -euo pipefail

TIDB_PORT="${TIDB_PORT:-4000}"
DUMPDIR="/tmp/dumpling_varchar_test"
CSVDIR="/tmp/import_into_csv_test"

mysql_cmd() { mysql --host 127.0.0.1 --port "$TIDB_PORT" -u root "$@"; }

echo "=== Phase 2: Dumpling → IMPORT INTO ==="

# --- Step 1: Create source with oversized data in VARCHAR(500) ---
echo ">> Step 1: Create source database with oversized data"
mysql_cmd -e "
  CREATE DATABASE IF NOT EXISTS source_db;
  SET GLOBAL sql_mode = 'ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES';
"
# New connection to pick up global sql_mode
mysql_cmd source_db -e "
  SELECT @@sql_mode AS sql_mode;
  DROP TABLE IF EXISTS contato;
  CREATE TABLE contato (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    codigo VARCHAR(15) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '',
    nome VARCHAR(500) CHARACTER SET utf8 COLLATE utf8_general_ci DEFAULT NULL
  );
  INSERT INTO contato (codigo, nome) VALUES
    ('001', REPEAT('A', 500)),
    ('002', REPEAT('B', 300)),
    ('003', 'Short name'),
    ('004', CONCAT(REPEAT('dados extras ', 40))),
    ('005', REPEAT('ã', 200)),
    ('006', REPEAT('X', 120));
  SELECT id, codigo, CHAR_LENGTH(nome) AS char_len FROM contato;
"

# --- Step 2: Dump with Dumpling ---
echo ">> Step 2: Dump with Dumpling"
rm -rf "$DUMPDIR" && mkdir -p "$DUMPDIR"
tiup dumpling:v8.5.1 \
  -h 127.0.0.1 -P "$TIDB_PORT" -u root \
  --filetype sql -o "$DUMPDIR" \
  -B source_db -T source_db.contato --no-views 2>&1 | tail -5

echo ">> Dump files:"
ls -la "$DUMPDIR/"

# --- Step 3: Edit DDL to VARCHAR(120) (simulate schema mismatch) ---
echo ">> Step 3: Edit dump DDL: VARCHAR(500) → VARCHAR(120)"
sed -i '' 's/varchar(500)/varchar(120)/g' "$DUMPDIR/source_db.contato-schema.sql"
echo ">> Edited DDL:"
cat "$DUMPDIR/source_db.contato-schema.sql"

# --- Step 4: Generate CSV with oversized data ---
echo ">> Step 4: Generate CSV with oversized data"
rm -rf "$CSVDIR" && mkdir -p "$CSVDIR"
python3 -c "
rows = [
    (1, '001', 'A' * 500),
    (2, '002', 'B' * 300),
    (3, '003', 'Short name'),
    (4, '004', 'dados extras ' * 40),
    (5, '005', 'X' * 120),
]
for r in rows:
    print(f'{r[0]},\"{r[1]}\",\"{r[2]}\"')
" > "$CSVDIR/contato.csv"

# --- Test A: IMPORT INTO from CSV, non-strict ---
echo ">> Test A: IMPORT INTO from CSV (non-strict)"
mysql_cmd -e "CREATE DATABASE IF NOT EXISTS target_csv;"
mysql_cmd target_csv -e "
  DROP TABLE IF EXISTS contato;
  CREATE TABLE contato (
    id BIGINT NOT NULL PRIMARY KEY,
    codigo VARCHAR(15) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '',
    nome VARCHAR(120) CHARACTER SET utf8 COLLATE utf8_general_ci DEFAULT NULL
  );
  IMPORT INTO contato FROM '$CSVDIR/contato.csv'
  WITH fields_terminated_by=',', fields_enclosed_by='\"';
"
echo ">> Stored lengths:"
mysql_cmd target_csv -e "SELECT id, CHAR_LENGTH(nome) AS char_len FROM contato ORDER BY id;"

# --- Test B: IMPORT INTO FORMAT 'sql' (Dumpling output), non-strict ---
echo ">> Test B: IMPORT INTO FORMAT sql (non-strict)"
mysql_cmd -e "CREATE DATABASE IF NOT EXISTS target_sql;"
mysql_cmd target_sql -e "
  DROP TABLE IF EXISTS contato;
  CREATE TABLE contato (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    codigo VARCHAR(15) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '',
    nome VARCHAR(120) CHARACTER SET utf8 COLLATE utf8_general_ci DEFAULT NULL
  );
  IMPORT INTO contato FROM '$DUMPDIR/source_db.contato.000000000.sql' FORMAT 'sql';
"
echo ">> Stored lengths:"
mysql_cmd target_sql -e "SELECT id, CHAR_LENGTH(nome) AS char_len FROM contato ORDER BY id;"

# --- Test C: IMPORT INTO FORMAT 'sql', STRICT mode ---
echo ">> Test C: IMPORT INTO FORMAT sql (STRICT mode)"
mysql_cmd -e "
  SET GLOBAL sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
"
# New connection with strict mode
mysql_cmd -e "CREATE DATABASE IF NOT EXISTS target_strict;"
mysql_cmd target_strict -e "
  DROP TABLE IF EXISTS contato;
  CREATE TABLE contato (
    id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    codigo VARCHAR(15) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '',
    nome VARCHAR(120) CHARACTER SET utf8 COLLATE utf8_general_ci DEFAULT NULL
  );
  SELECT @@sql_mode AS mode;
"
echo ">> Expecting ERROR 1406:"
mysql_cmd target_strict -e "
  IMPORT INTO contato FROM '$DUMPDIR/source_db.contato.000000000.sql' FORMAT 'sql';
" 2>&1 || true

# --- Test D: mysql < dump.sql, non-strict ---
echo ">> Test D: mysql CLI load (non-strict)"
mysql_cmd -e "
  SET GLOBAL sql_mode = 'ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES';
"
mysql_cmd -e "CREATE DATABASE IF NOT EXISTS target_cli;"
mysql_cmd target_cli < "$DUMPDIR/source_db.contato-schema.sql"
mysql_cmd target_cli < "$DUMPDIR/source_db.contato.000000000.sql" 2>&1 || true
echo ">> Stored lengths:"
mysql_cmd target_cli -e "SELECT id, CHAR_LENGTH(nome) AS char_len FROM contato ORDER BY id;"

# --- Test E: mysql < dump.sql, STRICT mode ---
echo ">> Test E: mysql CLI load (STRICT mode)"
mysql_cmd -e "
  SET GLOBAL sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
"
mysql_cmd -e "CREATE DATABASE IF NOT EXISTS target_strict_cli;"
mysql_cmd target_strict_cli < "$DUMPDIR/source_db.contato-schema.sql"
echo ">> Expecting ERROR 1406:"
mysql_cmd target_strict_cli < "$DUMPDIR/source_db.contato.000000000.sql" 2>&1 || true

# --- Reset ---
mysql_cmd -e "
  SET GLOBAL sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
"
echo "=== Phase 2 complete ==="
