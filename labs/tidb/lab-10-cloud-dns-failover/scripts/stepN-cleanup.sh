#!/usr/bin/env bash
# stepN-cleanup.sh — Stop containers, reset DNS
source "$(dirname "$0")/common.sh"

header "Cleanup"

docker compose down -v 2>/dev/null || true
docker network rm lab10-net 2>/dev/null || true

# Reset zone file to placeholder
cat > "$ZONE_FILE" <<'EOF'
$ORIGIN tidb.lab.
$TTL 5

@     IN  SOA  ns.tidb.lab. admin.tidb.lab. (
              1          ; serial
              3600       ; refresh
              600        ; retry
              86400      ; expire
              5 )        ; minimum

@     IN  NS   ns.tidb.lab.
ns    IN  A    172.30.0.10
db    IN  CNAME PLACEHOLDER_HOST.
EOF

echo "Containers stopped, zone file reset."
echo ""
echo "Results in: $RESULTS_DIR/"
ls -la "$RESULTS_DIR/" 2>/dev/null || true
