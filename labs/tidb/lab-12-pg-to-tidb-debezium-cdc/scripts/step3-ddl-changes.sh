#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=== Step 3: DDL Change Replication ==="

# ── S3: ADD COLUMN ─────────────────────────────────────────────
echo ""
echo "--- S3: ADD COLUMN ---"
echo "Adding 'city' column to PostgreSQL users table..."
pg_exec "ALTER TABLE users ADD COLUMN city VARCHAR(100);"

echo "Inserting row with new column..."
pg_exec "INSERT INTO users (name, email, city) VALUES ('Dave', 'dave@example.com', 'San Francisco');"

echo "Waiting ${CDC_WAIT}s for CDC replication..."
sleep "${CDC_WAIT}"

city=$(tidb_query "SELECT city FROM test.users WHERE name='Dave';")
assert_eq "S3: ADD COLUMN — new column + data replicated" "SanFrancisco" "$city"

# ── S4: ALTER COLUMN TYPE (widen VARCHAR) ──────────────────────
echo ""
echo "--- S4: ALTER COLUMN TYPE ---"
echo "Widening name column from VARCHAR(100) to VARCHAR(200) in PostgreSQL..."
pg_exec "ALTER TABLE users ALTER COLUMN name TYPE VARCHAR(200);"

long_name="ThisIsAVeryLongNameThatExceedsOneHundredCharacters_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
echo "Inserting row with long name (${#long_name} chars)..."
pg_exec "INSERT INTO users (name, email) VALUES ('${long_name}', 'longname@example.com');"

echo "Waiting ${CDC_WAIT}s for CDC replication..."
sleep "${CDC_WAIT}"

len=$(tidb_query "SELECT LENGTH(name) FROM test.users WHERE email='longname@example.com';")
assert_eq "S4: ALTER COLUMN TYPE — long value replicated" "${#long_name}" "$len"

# ── S5: DROP COLUMN ────────────────────────────────────────────
echo ""
echo "--- S5: DROP COLUMN ---"
echo "Dropping 'city' column from PostgreSQL..."
pg_exec "ALTER TABLE users DROP COLUMN city;"

echo "Inserting row after column drop..."
pg_exec "INSERT INTO users (name, email) VALUES ('Eve', 'eve@example.com');"

echo "Waiting ${CDC_WAIT}s for CDC replication..."
sleep "${CDC_WAIT}"

# JDBC sink does NOT auto-drop columns — 'city' should still exist in TiDB
# but new rows will have NULL for the dropped column.
eve_exists=$(tidb_query "SELECT COUNT(*) FROM test.users WHERE name='Eve';")
assert_eq "S5: DROP COLUMN — new row replicated" "1" "$eve_exists"

city_col=$(tidb_query "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='test' AND table_name='users' AND column_name='city';")
assert_eq "S5: DROP COLUMN — column still exists in TiDB (no auto-drop)" "1" "$city_col"

eve_city=$(tidb_query "SELECT IFNULL(city, 'NULL') FROM test.users WHERE name='Eve';")
assert_eq "S5: DROP COLUMN — Eve's city is NULL" "NULL" "$eve_city"

# ── Show state ─────────────────────────────────────────────────
echo ""
echo "Current TiDB state (note: city column retained after PG drop):"
tidb_exec "SELECT id, name, email, city FROM test.users ORDER BY id;"

print_summary

echo ""
echo "=== Step 3 completed ==="
