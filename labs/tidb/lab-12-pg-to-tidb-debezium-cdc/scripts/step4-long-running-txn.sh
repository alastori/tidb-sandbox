#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=== Step 4: Long-Running Transaction Behavior ==="

# ── S6: COMMIT — rows appear only after commit ────────────────
echo ""
echo "--- S6: Long-running transaction (COMMIT) ---"
echo "Starting transaction with pg_sleep(15) before commit..."

# Record row count before the transaction
pre_count=$(tidb_query "SELECT COUNT(*) FROM test.users WHERE name LIKE 'LongTxn%';")

# Run long transaction in background
dc exec -T postgres psql -U postgres -d smoketest <<'SQL' &
BEGIN;
INSERT INTO users (name, email) VALUES ('LongTxn1', 'longtxn1@example.com');
INSERT INTO users (name, email) VALUES ('LongTxn2', 'longtxn2@example.com');
INSERT INTO users (name, email) VALUES ('LongTxn3', 'longtxn3@example.com');
SELECT pg_sleep(15);
COMMIT;
SQL
TXN_PID=$!

# Check mid-transaction (PG txn still open, nothing committed yet)
echo "Checking TiDB mid-transaction (after 5s, txn still open)..."
sleep 5
mid_count=$(tidb_query "SELECT COUNT(*) FROM test.users WHERE name LIKE 'LongTxn%';")
assert_eq "S6: Mid-transaction — no rows visible in TiDB yet" "$pre_count" "$mid_count"

# Wait for the transaction to finish
echo "Waiting for transaction to complete..."
wait $TXN_PID || true

# Wait for CDC to propagate the committed changes
echo "Waiting ${CDC_WAIT}s for CDC replication..."
sleep "${CDC_WAIT}"

post_count=$(tidb_query "SELECT COUNT(*) FROM test.users WHERE name LIKE 'LongTxn%';")
assert_eq "S6: After COMMIT — 3 rows appear in TiDB" "3" "$post_count"

# ── S7: ROLLBACK — no rows produced ───────────────────────────
echo ""
echo "--- S7: Transaction ROLLBACK ---"
echo "Starting and rolling back a transaction..."

dc exec -T postgres psql -U postgres -d smoketest <<'SQL'
BEGIN;
INSERT INTO users (name, email) VALUES ('Ghost1', 'ghost1@example.com');
INSERT INTO users (name, email) VALUES ('Ghost2', 'ghost2@example.com');
ROLLBACK;
SQL

echo "Waiting ${CDC_WAIT}s for any CDC events..."
sleep "${CDC_WAIT}"

ghost_count=$(tidb_query "SELECT COUNT(*) FROM test.users WHERE name LIKE 'Ghost%';")
assert_eq "S7: ROLLBACK — no ghost rows in TiDB" "0" "$ghost_count"

# ── Show final state ──────────────────────────────────────────
echo ""
echo "Current TiDB state:"
tidb_exec "SELECT id, name, email FROM test.users ORDER BY id;"

print_summary

echo ""
echo "=== Step 4 completed ==="
