#!/usr/bin/env bash
# Phase 3: Lightning local backend — test VARCHAR enforcement at KV level
# Prereq: tiup playground v8.5.1 running on $TIDB_PORT
set -euo pipefail

TIDB_PORT="${TIDB_PORT:-4000}"
LIGHTNING_DIR="/tmp/lightning_varchar_test"

mysql_cmd() { mysql --host 127.0.0.1 --port "$TIDB_PORT" -u root "$@"; }

echo "=== Phase 3: Lightning Local Backend ==="

# --- Prepare data source (Dumpling-format SQL files) ---
echo ">> Preparing Lightning data source"
rm -rf "$LIGHTNING_DIR"
mkdir -p "$LIGHTNING_DIR/data" "$LIGHTNING_DIR/sorted-kv"

cat > "$LIGHTNING_DIR/data/lightning_db-schema-create.sql" <<'SQL'
CREATE DATABASE IF NOT EXISTS `lightning_db`;
SQL

cat > "$LIGHTNING_DIR/data/lightning_db.contato-schema.sql" <<'SQL'
CREATE TABLE `contato` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `codigo` varchar(15) CHARACTER SET utf8 COLLATE utf8_general_ci NOT NULL DEFAULT '',
  `nome` varchar(120) CHARACTER SET utf8 COLLATE utf8_general_ci DEFAULT NULL,
  PRIMARY KEY (`id`) CLUSTERED
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
SQL

# Data file: DDL says VARCHAR(120) but data has 500-char values
python3 -c "
a500 = 'A' * 500
b300 = 'B' * 300
x120 = 'X' * 120
print('''/*!40014 SET FOREIGN_KEY_CHECKS=0*/;
/*!40101 SET NAMES binary*/;
INSERT INTO \x60contato\x60 VALUES
(1,'001','%s'),
(2,'002','%s'),
(3,'003','Short name'),
(4,'004','%s');''' % (a500, b300, x120))
" > "$LIGHTNING_DIR/data/lightning_db.contato.000000000.sql"

echo ">> Data file row lengths:"
python3 -c "
with open('$LIGHTNING_DIR/data/lightning_db.contato.000000000.sql') as f:
    content = f.read()
    for i, val in enumerate(['A'*500, 'B'*300, 'Short name', 'X'*120], 1):
        if val[:10] in content:
            print(f'  Row {i}: {len(val)} chars')
"

# --- Lightning config ---
cat > "$LIGHTNING_DIR/lightning.toml" <<TOML
[lightning]
level = "info"

[tikv-importer]
backend = "local"
sorted-kv-dir = "$LIGHTNING_DIR/sorted-kv"

[mydumper]
data-source-dir = "$LIGHTNING_DIR/data"

[tidb]
host = "127.0.0.1"
port = $TIDB_PORT
user = "root"
password = ""
status-port = 10080
pd-addr = "127.0.0.1:2379"
TOML

# --- Test F: Lightning v8.5.1 ---
test_lightning() {
  local version="$1"
  local extra_flags="${2:-}"
  echo ">> Test: Lightning $version (local backend)"

  mysql_cmd -e "DROP DATABASE IF EXISTS lightning_db;" 2>/dev/null
  rm -rf "$LIGHTNING_DIR/sorted-kv"/*

  tiup "tidb-lightning:$version" \
    --config "$LIGHTNING_DIR/lightning.toml" \
    $extra_flags 2>&1 | tail -3

  echo ">> Stored lengths:"
  mysql_cmd lightning_db -e "
    SELECT id, CHAR_LENGTH(nome) AS char_len, LENGTH(nome) AS byte_len
    FROM contato ORDER BY id;
  "

  # Verify truncation
  mysql_cmd lightning_db -e "
    SELECT id,
      nome = REPEAT('A', 500) AS is_full_500,
      nome = REPEAT('A', 120) AS is_truncated_120
    FROM contato WHERE id = 1;
  "
}

test_lightning "v8.5.1"
test_lightning "v6.5.0" "--check-requirements=false"

echo "=== Phase 3 complete ==="
