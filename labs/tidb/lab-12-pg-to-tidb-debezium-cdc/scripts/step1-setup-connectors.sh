#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=== Step 1: Register Kafka Connect Connectors ==="

# ── Debezium PostgreSQL source connector ───────────────────────
echo ""
echo "Registering Debezium PostgreSQL source connector..."
curl -sf -X POST "${CONNECT_URL}/connectors" \
    -H "Content-Type: application/json" \
    -d "$(cat <<EOF
{
    "name": "pg-source",
    "config": {
        "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
        "database.hostname": "postgres",
        "database.port": "5432",
        "database.user": "${PG_USER}",
        "database.password": "${PG_PASSWORD}",
        "database.dbname": "${PG_DB}",
        "topic.prefix": "pg",
        "schema.include.list": "public",
        "table.include.list": "public.users",
        "plugin.name": "pgoutput",
        "slot.name": "debezium_slot",
        "publication.name": "dbz_publication"
    }
}
EOF
)" > /dev/null
echo "  pg-source registered."

# ── JDBC Sink connector for TiDB ──────────────────────────────
echo ""
echo "Registering JDBC sink connector for TiDB..."
curl -sf -X POST "${CONNECT_URL}/connectors" \
    -H "Content-Type: application/json" \
    -d '{
    "name": "tidb-sink",
    "config": {
        "connector.class": "io.confluent.connect.jdbc.JdbcSinkConnector",
        "connection.url": "jdbc:mysql://tidb:4000/test?useSSL=false&allowPublicKeyRetrieval=true",
        "connection.user": "root",
        "connection.password": "",
        "topics": "pg.public.users",
        "insert.mode": "upsert",
        "pk.mode": "record_key",
        "pk.fields": "id",
        "auto.create": "true",
        "auto.evolve": "true",
        "delete.enabled": "false",
        "transforms": "unwrap,route",
        "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
        "transforms.unwrap.drop.tombstones": "true",
        "transforms.route.type": "org.apache.kafka.connect.transforms.RegexRouter",
        "transforms.route.regex": "([^.]+)\\.([^.]+)\\.([^.]+)",
        "transforms.route.replacement": "$3"
    }
}' > /dev/null
echo "  tidb-sink registered."

# ── Wait for connectors to initialize ─────────────────────────
echo ""
echo "Waiting for connectors to initialize..."
sleep 10

for conn in pg-source tidb-sink; do
    state=$(curl -sf "${CONNECT_URL}/connectors/${conn}/status" | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['connector']['state'])")
    if [[ "$state" == "RUNNING" ]]; then
        echo "  ✅ Connector ${conn} is RUNNING"
    else
        echo "  ❌ Connector ${conn} state: ${state}"
        curl -sf "${CONNECT_URL}/connectors/${conn}/status" | python3 -m json.tool
        exit 1
    fi
done

echo ""
echo "=== Step 1 completed ==="
