#!/usr/bin/env bash
# Phase 8a: MODIFY COLUMN Metadata Corruption Hypothesis
#
# Hypothesis: Known TiDB bugs #39915 and #40620 — MODIFY COLUMN on partitioned
# tables with indexes can corrupt adjacent column metadata (Flen → -1),
# disabling VARCHAR truncation.
#
# Production timeline: MODIFY COLUMN codigoBarras VARCHAR(48) in Dec 2025,
# oversized data appears in Feb 2026.
#
# This script reproduces the exact DDL sequence from production on the full
# gnre schema (39 columns, 4 indexes, PARTITION BY KEY 128).
#
# Prereq: tiup playground v8.5.1 running on $TIDB_PORT
set -euo pipefail

TIDB_PORT="${TIDB_PORT:-4000}"
NONSTRICT="ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,ALLOW_INVALID_DATES"

mysql_cmd() { mysql --host 127.0.0.1 --port "$TIDB_PORT" -u root "$@"; }

echo "=== Phase 8a: MODIFY COLUMN Metadata Corruption ==="
echo "    Hypothesis: DDL on codigoBarras corrupts Flen of enderecoDestinatario"
echo ""

mysql_cmd -e "DROP DATABASE IF EXISTS phase8a_test; CREATE DATABASE phase8a_test DEFAULT CHARSET utf8 COLLATE utf8_general_ci;"
mysql_cmd -e "SET GLOBAL sql_mode = '$NONSTRICT';"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Full gnre schema from production (39 columns, all indexes)
# ---------------------------------------------------------------------------
create_gnre() {
  mysql_cmd phase8a_test -e "
    DROP TABLE IF EXISTS gnre;
    CREATE TABLE gnre (
      id BIGINT NOT NULL AUTO_INCREMENT,
      idEmpresa BIGINT NOT NULL,
      situacao TINYINT DEFAULT NULL,
      idContato BIGINT DEFAULT NULL,
      codigoBarras VARCHAR(44) COLLATE utf8_general_ci DEFAULT NULL,
      enderecoDestinatario VARCHAR(70) COLLATE utf8_general_ci NOT NULL,
      tipoDocumentoOrigem TINYINT DEFAULT NULL,
      documentoOrigem VARCHAR(50) COLLATE utf8_general_ci DEFAULT NULL,
      valorGNRE DECIMAL(16,4) DEFAULT NULL,
      dataVencimento DATE DEFAULT NULL,
      dataLimitePagamento DATE DEFAULT NULL,
      dataPagamento DATE DEFAULT NULL,
      dataCriacao DATETIME DEFAULT NULL,
      periodoReferencia VARCHAR(10) COLLATE utf8_general_ci DEFAULT NULL,
      parcela INT DEFAULT NULL,
      receita INT DEFAULT NULL,
      ufFavorecida VARCHAR(2) COLLATE utf8_general_ci DEFAULT NULL,
      razaoSocialDestinatario VARCHAR(60) COLLATE utf8_general_ci DEFAULT NULL,
      municipioDestinatario INT DEFAULT NULL,
      inscricaoEstadual VARCHAR(20) COLLATE utf8_general_ci DEFAULT NULL,
      cpfCnpjDestinatario VARCHAR(20) COLLATE utf8_general_ci DEFAULT NULL,
      convenio VARCHAR(30) COLLATE utf8_general_ci DEFAULT NULL,
      produto VARCHAR(30) COLLATE utf8_general_ci DEFAULT NULL,
      detalhamentoReceita INT DEFAULT NULL,
      idNota BIGINT DEFAULT NULL,
      numero INT DEFAULT NULL,
      observacao TEXT COLLATE utf8_general_ci,
      idRecebimento BIGINT DEFAULT NULL,
      tipoIdentificacaoEmitente TINYINT DEFAULT NULL,
      camposExtras TEXT COLLATE utf8_general_ci,
      valorFECP DECIMAL(16,4) DEFAULT NULL,
      valorICMS DECIMAL(16,4) DEFAULT NULL,
      idOrigem BIGINT DEFAULT NULL,
      tipoGnre TINYINT DEFAULT NULL,
      tipoIcmsDesonerado TINYINT DEFAULT NULL,
      tipoIcmsDesonerar TINYINT DEFAULT NULL,
      valorIcmsDesonerado DECIMAL(16,4) DEFAULT NULL,
      atualizadoPelaDifal TINYINT DEFAULT NULL,
      ambiente TINYINT DEFAULT NULL,
      PRIMARY KEY (id, idEmpresa) /*T![clustered_index] CLUSTERED */,
      KEY idx_idEmpresa_situacao (idEmpresa, situacao),
      KEY idx_idNota (idNota),
      KEY idx_idRecebimento (idRecebimento),
      KEY idx_codigoBarras (codigoBarras)
    ) AUTO_ID_CACHE 1
    PARTITION BY KEY (idEmpresa) PARTITIONS 128;
  "
}

check_oversized() {
  local test_num="$1" desc="$2"
  local count
  count=$(mysql_cmd -N phase8a_test -e "
    SELECT COUNT(*) FROM gnre WHERE CHAR_LENGTH(enderecoDestinatario) > 70;
  ")
  if [ "$count" -eq 0 ]; then
    printf "  8a-%-2s %-55s → oversized=0 (PASS)\n" "$test_num" "$desc"
    PASS=$((PASS + 1))
  else
    printf "  8a-%-2s %-55s → oversized=%s (FAIL!)\n" "$test_num" "$desc" "$count"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Test 8a-1: Exact production DDL sequence
# Production: CREATE TABLE → ADD INDEX → MODIFY COLUMN codigoBarras 44→48
# ---------------------------------------------------------------------------
echo "--- Test 8a-1: Exact production DDL sequence ---"
create_gnre

# Reproduce the exact DDL operations from production DDL_JOBS:
# 1. CREATE TABLE (done above)
# 2. ADD INDEX (already has indexes, add another like prod's placement policy timing)
mysql_cmd phase8a_test -e "ALTER TABLE gnre ADD INDEX idx_extra (dataCriacao);"
# 3. MODIFY COLUMN codigoBarras VARCHAR(44) → VARCHAR(48) (the December 2025 DDL)
mysql_cmd phase8a_test -e "ALTER TABLE gnre MODIFY COLUMN codigoBarras VARCHAR(48) COLLATE utf8_general_ci DEFAULT NULL;"

# Now insert oversized data
mysql_cmd phase8a_test -e "
SET SESSION sql_mode='$NONSTRICT';
SET NAMES utf8mb4;
INSERT INTO gnre (idEmpresa, codigoBarras, enderecoDestinatario, razaoSocialDestinatario)
VALUES
  (100, 'BAR001', REPEAT('A', 200), 'Test Empresa 1'),
  (200, 'BAR002', REPEAT('B', 200), 'Test Empresa 2'),
  (300, 'BAR003', REPEAT('C', 200), 'Test Empresa 3');
"

check_oversized 1 "Exact prod DDL sequence (CREATE→ADD INDEX→MODIFY COL)"

# ---------------------------------------------------------------------------
# Test 8a-2: Concurrent DDL + inserts (50 threads)
# ---------------------------------------------------------------------------
echo "--- Test 8a-2: Concurrent DDL + inserts ---"
create_gnre

# Start 50 concurrent inserts
for i in $(seq 1 50); do
  mysql_cmd phase8a_test -N -e "
    SET SESSION sql_mode='$NONSTRICT';
    SET NAMES utf8mb4;
    INSERT INTO gnre (idEmpresa, codigoBarras, enderecoDestinatario)
      VALUES ($i, 'CONC$i', REPEAT('X', 200));
  " 2>/dev/null &
done

# DDL during inserts (may fail due to schema change conflicts — expected)
mysql_cmd phase8a_test -e "ALTER TABLE gnre MODIFY COLUMN codigoBarras VARCHAR(48) COLLATE utf8_general_ci DEFAULT NULL;" 2>/dev/null || true

# More inserts after DDL
for i in $(seq 51 100); do
  mysql_cmd phase8a_test -N -e "
    SET SESSION sql_mode='$NONSTRICT';
    SET NAMES utf8mb4;
    INSERT INTO gnre (idEmpresa, codigoBarras, enderecoDestinatario)
      VALUES ($i, 'CONC$i', REPEAT('Y', 200));
  " 2>/dev/null &
done

wait || true  # background jobs may fail due to schema change conflicts
check_oversized 2 "Concurrent DDL + 100 inserts (50 before, 50 after)"

# ---------------------------------------------------------------------------
# Test 8a-3: Rapid DDL cycling (5 rounds of 44→48→44→48)
# ---------------------------------------------------------------------------
echo "--- Test 8a-3: Rapid DDL cycling ---"
create_gnre

for cycle in 1 2 3 4 5; do
  mysql_cmd phase8a_test -e "ALTER TABLE gnre MODIFY COLUMN codigoBarras VARCHAR(44) COLLATE utf8_general_ci DEFAULT NULL;" 2>/dev/null || true

  for j in $(seq 1 10); do
    idx=$(( (cycle - 1) * 10 + j ))
    mysql_cmd phase8a_test -N -e "
      SET SESSION sql_mode='$NONSTRICT';
      SET NAMES utf8mb4;
      INSERT INTO gnre (idEmpresa, codigoBarras, enderecoDestinatario)
        VALUES ($idx, 'CYCLE$idx', REPEAT('Z', 200));
    " 2>/dev/null &
  done

  mysql_cmd phase8a_test -e "ALTER TABLE gnre MODIFY COLUMN codigoBarras VARCHAR(48) COLLATE utf8_general_ci DEFAULT NULL;" 2>/dev/null || true
done

wait || true  # background jobs may fail due to schema change conflicts
check_oversized 3 "Rapid DDL cycling (5 rounds × 10 inserts each)"

# ---------------------------------------------------------------------------
# Cleanup & Summary
# ---------------------------------------------------------------------------
echo ""
mysql_cmd -e "DROP DATABASE IF EXISTS phase8a_test;"

echo "=== Phase 8a Summary ==="
echo "  Pass: $PASS / $((PASS + FAIL))"
echo "  Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  *** BYPASS DETECTED — MODIFY COLUMN corrupted column metadata ***"
  exit 1
else
  echo "  MODIFY COLUMN does NOT corrupt adjacent column Flen on v8.5.1"
fi
