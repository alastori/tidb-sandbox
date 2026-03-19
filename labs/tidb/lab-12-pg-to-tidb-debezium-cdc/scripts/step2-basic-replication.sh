#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=== Step 2: Basic Replication (INSERT + UPDATE) ==="

# ── S1: INSERT replication ─────────────────────────────────────
echo ""
echo "--- S1: INSERT replication ---"
echo "Inserting 3 rows into PostgreSQL..."
pg_exec "INSERT INTO users (name, email) VALUES
    ('Alice', 'alice@example.com'),
    ('Bob',   'bob@example.com'),
    ('Carol', 'carol@example.com');"

echo "Waiting ${CDC_WAIT}s for CDC replication..."
sleep "${CDC_WAIT}"

count=$(tidb_query "SELECT COUNT(*) FROM test.users;")
assert_eq "S1: 3 rows replicated to TiDB" "3" "$count"

# ── S2: UPDATE replication ─────────────────────────────────────
echo ""
echo "--- S2: UPDATE replication ---"
echo "Updating Alice's email in PostgreSQL..."
pg_exec "UPDATE users SET email = 'alice-new@example.com' WHERE name = 'Alice';"

echo "Waiting ${CDC_WAIT}s for CDC replication..."
sleep "${CDC_WAIT}"

updated=$(tidb_query "SELECT email FROM test.users WHERE name='Alice';")
assert_eq "S2: UPDATE propagated to TiDB" "alice-new@example.com" "$updated"

# ── Show current state ─────────────────────────────────────────
echo ""
echo "Current TiDB state:"
tidb_exec "SELECT id, name, email FROM test.users ORDER BY id;"

print_summary

echo ""
echo "=== Step 2 completed ==="
