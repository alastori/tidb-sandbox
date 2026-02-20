#!/usr/bin/env bash
# Phase 8c: Multi-Node Schema Cache Divergence Hypothesis
#
# Hypothesis: In multi-TiDB-node clusters, DDL on one node could cause
# stale schema cache on other nodes, leading to different truncation behavior.
# Specifically, MODIFY COLUMN on Node 1 could corrupt metadata on Node 2.
#
# Prereq: tiup playground v8.5.1 with TWO TiDB nodes:
#   tiup playground v8.5.1 --db 2 --pd 1 --kv 1 --tiflash 0 --without-monitor
#
# Set TIDB_PORT_1 and TIDB_PORT_2 to the two TiDB ports.
# The playground will print them, e.g.:
#   Connect TiDB: mysql --host 127.0.0.1 --port 63274 -u root
#   Connect TiDB: mysql --host 127.0.0.1 --port 63276 -u root
set -euo pipefail

TIDB_PORT_1="${TIDB_PORT_1:-4000}"
TIDB_PORT_2="${TIDB_PORT_2:-4001}"
NONSTRICT="ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES"

node1() { mysql --host 127.0.0.1 --port "$TIDB_PORT_1" -u root "$@"; }
node2() { mysql --host 127.0.0.1 --port "$TIDB_PORT_2" -u root "$@"; }

echo "=== Phase 8c: Multi-Node Schema Cache Divergence ==="
echo "    Node 1: port $TIDB_PORT_1"
echo "    Node 2: port $TIDB_PORT_2"
echo ""

# Verify both nodes are alive
echo "--- Verifying both nodes ---"
node1 -N -e "SELECT 'node1_alive';" || { echo "ERROR: Node 1 (port $TIDB_PORT_1) not reachable"; exit 1; }
node2 -N -e "SELECT 'node2_alive';" || { echo "ERROR: Node 2 (port $TIDB_PORT_2) not reachable"; exit 1; }

# Setup
node1 -e "DROP DATABASE IF EXISTS phase8c_test; CREATE DATABASE phase8c_test DEFAULT CHARSET utf8 COLLATE utf8_general_ci;"
node1 -e "SET GLOBAL sql_mode = '$NONSTRICT';"
node2 -e "SET GLOBAL sql_mode = '$NONSTRICT';"

sleep 3

# Verify Node 2 sees the database
echo "Node 2 sees phase8c_test:"
node2 -N -e "SHOW DATABASES LIKE 'phase8c_test';" || { echo "ERROR: Node 2 cannot see phase8c_test"; exit 1; }
echo ""

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helper: create gnre-like table via Node 1
# ---------------------------------------------------------------------------
create_table() {
  node1 phase8c_test -e "
    DROP TABLE IF EXISTS gnre;
    CREATE TABLE gnre (
      id BIGINT NOT NULL AUTO_INCREMENT,
      idEmpresa BIGINT NOT NULL,
      codigoBarras VARCHAR(44) COLLATE utf8_general_ci DEFAULT NULL,
      enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
      col3 VARCHAR(100) COLLATE utf8_general_ci DEFAULT NULL,
      col4 VARCHAR(100) COLLATE utf8_general_ci DEFAULT NULL,
      col5 DATETIME DEFAULT NULL,
      PRIMARY KEY (id, idEmpresa) /*T![clustered_index] CLUSTERED */,
      KEY idx_empresa (idEmpresa),
      KEY idx_barras (codigoBarras)
    ) AUTO_ID_CACHE 1
    PARTITION BY KEY (idEmpresa) PARTITIONS 128;
  "
  sleep 2  # schema sync time
}

check_oversized() {
  local test_num="$1" desc="$2"
  local count
  count=$(node1 -N phase8c_test -e "
    SELECT COUNT(*) FROM gnre WHERE CHAR_LENGTH(enderecoDestinatario) > 70;
  ")
  if [ "$count" -eq 0 ]; then
    printf "  8c-%-2s %-55s → oversized=0 (PASS)\n" "$test_num" "$desc"
    PASS=$((PASS + 1))
  else
    printf "  8c-%-2s %-55s → oversized=%s (FAIL!)\n" "$test_num" "$desc" "$count"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Test 8c-1: Baseline — INSERT from both nodes before any DDL
# ---------------------------------------------------------------------------
echo "--- Test 8c-1: Baseline — INSERT from both nodes (pre-DDL) ---"
create_table

node1 phase8c_test -e "
SET SESSION sql_mode='$NONSTRICT';
SET NAMES utf8mb4;
INSERT INTO gnre (idEmpresa, codigoBarras, enderecoDestinatario)
  VALUES (1, 'N1BAR', REPEAT('A', 200));
"

node2 phase8c_test -e "
SET SESSION sql_mode='$NONSTRICT';
SET NAMES utf8mb4;
INSERT INTO gnre (idEmpresa, codigoBarras, enderecoDestinatario)
  VALUES (2, 'N2BAR', REPEAT('B', 200));
"

check_oversized 1 "Baseline: INSERT from both nodes (pre-DDL)"

# ---------------------------------------------------------------------------
# Test 8c-2: MODIFY COLUMN on Node 1, INSERT from Node 2
# ---------------------------------------------------------------------------
echo "--- Test 8c-2: MODIFY COLUMN on Node 1, INSERT from Node 2 ---"
create_table

# DDL on Node 1
node1 phase8c_test -e "ALTER TABLE gnre MODIFY COLUMN codigoBarras VARCHAR(48) COLLATE utf8_general_ci DEFAULT NULL;"
sleep 2

# Verify schema on both nodes
echo "  Node 1 schema: $(node1 -N phase8c_test -e "SELECT COLUMN_TYPE FROM information_schema.columns WHERE table_schema='phase8c_test' AND table_name='gnre' AND column_name='codigoBarras';")"
echo "  Node 2 schema: $(node2 -N phase8c_test -e "SELECT COLUMN_TYPE FROM information_schema.columns WHERE table_schema='phase8c_test' AND table_name='gnre' AND column_name='codigoBarras';")"

# INSERT from Node 2 (didn't execute DDL)
node2 phase8c_test -e "
SET SESSION sql_mode='$NONSTRICT';
SET NAMES utf8mb4;
INSERT INTO gnre (idEmpresa, codigoBarras, enderecoDestinatario)
  VALUES (3, 'N2POST', REPEAT('C', 200));
"

# INSERT from Node 1 (DDL executor)
node1 phase8c_test -e "
SET SESSION sql_mode='$NONSTRICT';
SET NAMES utf8mb4;
INSERT INTO gnre (idEmpresa, codigoBarras, enderecoDestinatario)
  VALUES (4, 'N1POST', REPEAT('D', 200));
"

check_oversized 2 "MODIFY COLUMN on Node 1, INSERT from Node 2"

# ---------------------------------------------------------------------------
# Test 8c-3: Rapid DDL toggle + concurrent inserts from both nodes
# ---------------------------------------------------------------------------
echo "--- Test 8c-3: Rapid DDL toggle + concurrent inserts (both nodes) ---"
create_table

# 50 concurrent inserts from Node 2
for i in $(seq 1 50); do
  node2 phase8c_test -N -e "
    SET SESSION sql_mode='$NONSTRICT';
    SET NAMES utf8mb4;
    INSERT INTO gnre (idEmpresa, codigoBarras, enderecoDestinatario)
      VALUES ($i, 'N2R$i', REPEAT('X', 200));
  " 2>/dev/null &
done

# Rapid DDL from Node 1 interleaved with inserts
for cycle in 1 2 3 4 5; do
  node1 phase8c_test -e "ALTER TABLE gnre MODIFY COLUMN codigoBarras VARCHAR(44) COLLATE utf8_general_ci DEFAULT NULL;" 2>/dev/null || true

  for j in $(seq 1 10); do
    idx=$(( (cycle - 1) * 10 + j + 100 ))
    node1 phase8c_test -N -e "
      SET SESSION sql_mode='$NONSTRICT';
      SET NAMES utf8mb4;
      INSERT INTO gnre (idEmpresa, codigoBarras, enderecoDestinatario)
        VALUES ($idx, 'N1R$idx', REPEAT('Y', 200));
    " 2>/dev/null &
  done

  node1 phase8c_test -e "ALTER TABLE gnre MODIFY COLUMN codigoBarras VARCHAR(48) COLLATE utf8_general_ci DEFAULT NULL;" 2>/dev/null || true
done

wait || true  # background jobs may fail due to schema change conflicts
check_oversized 3 "Rapid DDL toggle (5 cycles) + concurrent inserts"

# ---------------------------------------------------------------------------
# Test 8c-4: DDL race (ADD/DROP INDEX + MODIFY) during Node 2 inserts
# ---------------------------------------------------------------------------
echo "--- Test 8c-4: DDL race (ADD/DROP/MODIFY) during Node 2 inserts ---"
create_table

# 100 tight inserts from Node 2
for i in $(seq 1 100); do
  node2 phase8c_test -N -e "
    SET SESSION sql_mode='$NONSTRICT';
    SET NAMES utf8mb4;
    INSERT INTO gnre (idEmpresa, codigoBarras, enderecoDestinatario)
      VALUES ($i, 'RACE$i', REPEAT('Z', 200));
  " 2>/dev/null &
done

# Complex DDL sequence from Node 1 (production DDL pattern)
# These may fail due to racing with concurrent inserts — expected
node1 phase8c_test -e "ALTER TABLE gnre ADD INDEX idx_col3 (col3);" 2>/dev/null || true
node1 phase8c_test -e "ALTER TABLE gnre MODIFY COLUMN codigoBarras VARCHAR(44) COLLATE utf8_general_ci DEFAULT NULL;" 2>/dev/null || true
node1 phase8c_test -e "ALTER TABLE gnre MODIFY COLUMN codigoBarras VARCHAR(48) COLLATE utf8_general_ci DEFAULT NULL;" 2>/dev/null || true
node1 phase8c_test -e "ALTER TABLE gnre DROP INDEX idx_col3;" 2>/dev/null || true

wait || true  # background jobs may fail due to schema change conflicts
check_oversized 4 "DDL race (ADD/DROP INDEX + MODIFY) during inserts"

# ---------------------------------------------------------------------------
# Test 8c-5: Bulk DML (tidb_dml_type='bulk') + multi-node + DDL
# ---------------------------------------------------------------------------
echo "--- Test 8c-5: Bulk DML + multi-node + DDL ---"
create_table

# Bulk DML inserts from Node 2
for i in $(seq 1 50); do
  node2 phase8c_test -N -e "
    SET SESSION sql_mode='$NONSTRICT';
    SET NAMES utf8mb4;
    SET SESSION tidb_dml_type='bulk';
    INSERT INTO gnre (idEmpresa, codigoBarras, enderecoDestinatario)
      VALUES ($i, 'BULK$i', REPEAT('W', 200));
  " 2>/dev/null &
done

# Rapid DDL from Node 1
node1 phase8c_test -e "ALTER TABLE gnre MODIFY COLUMN codigoBarras VARCHAR(44) COLLATE utf8_general_ci DEFAULT NULL;" 2>/dev/null || true
node1 phase8c_test -e "ALTER TABLE gnre MODIFY COLUMN codigoBarras VARCHAR(48) COLLATE utf8_general_ci DEFAULT NULL;" 2>/dev/null || true

wait || true  # background jobs may fail due to schema change conflicts
check_oversized 5 "Bulk DML (tidb_dml_type=bulk) + multi-node + DDL"

# ---------------------------------------------------------------------------
# Test 8c-6: ADMIN CHECK TABLE
# ---------------------------------------------------------------------------
echo "--- Test 8c-6: ADMIN CHECK TABLE ---"
node1 phase8c_test -e "ADMIN CHECK TABLE gnre;" 2>&1
admin_rc=$?
if [ "$admin_rc" -eq 0 ]; then
  printf "  8c-%-2s %-55s → no corruption (PASS)\n" "6" "ADMIN CHECK TABLE"
  PASS=$((PASS + 1))
else
  printf "  8c-%-2s %-55s → ERROR (FAIL!)\n" "6" "ADMIN CHECK TABLE"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Cleanup & Summary
# ---------------------------------------------------------------------------
echo ""
node1 -e "DROP DATABASE IF EXISTS phase8c_test;"

echo "=== Phase 8c Summary ==="
echo "  Pass: $PASS / $((PASS + FAIL))"
echo "  Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  *** BYPASS DETECTED — multi-node schema divergence causes truncation failure ***"
  exit 1
else
  echo "  Multi-node schema cache does NOT cause truncation failure on v8.5.1"
fi
