# Sourced by step scripts — not executed directly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$LAB_DIR"

# Load .env if present
if [[ -f .env ]]; then
    set -a
    # shellcheck source=/dev/null
    source .env
    set +a
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
RESULTS_DIR="$LAB_DIR/results"
mkdir -p "$RESULTS_DIR"

# Network
DNS_IP=172.30.0.10
DNS_PORT=5300           # Host-side port
DNS_SERVER_INTERNAL="${DNS_IP}:53"

# Zone file
ZONE_FILE="$LAB_DIR/conf/coredns/db.lab"

# Probe defaults (overridable via .env)
PROBE_DURATION="${PROBE_DURATION:-60}"
PROBE_INTERVAL="${PROBE_INTERVAL:-2}"

# --- Utility functions ---

find_mysql() {
    for cmd in mysql /opt/homebrew/opt/mysql-client/bin/mysql /usr/local/opt/mysql-client/bin/mysql; do
        if command -v "$cmd" &>/dev/null; then
            echo "$cmd"
            return
        fi
    done
    echo ""
}

dns_flip() {
    # dns_flip <cname_target> <ttl>
    local target="$1"
    local ttl="${2:-5}"
    local serial
    serial=$(date +%s)

    cat > "$ZONE_FILE" <<EOF
\$ORIGIN tidb.lab.
\$TTL ${ttl}

@     IN  SOA  ns.tidb.lab. admin.tidb.lab. (
              ${serial}  ; serial
              3600       ; refresh
              600        ; retry
              86400      ; expire
              ${ttl} )   ; minimum

@     IN  NS   ns.tidb.lab.
ns    IN  A    172.30.0.10
db    IN  CNAME ${target}.
EOF

    # If CoreDNS is running, restart to pick up zone file change (volume-mounted)
    if docker inspect lab10-coredns &>/dev/null 2>&1; then
        docker restart lab10-coredns >/dev/null 2>&1
    fi

    echo "DNS flipped: db.tidb.lab → CNAME ${target} (TTL=${ttl})"
}

dns_resolve() {
    # Resolve db.tidb.lab via local CoreDNS — return CNAME target
    dig +short +tcp @127.0.0.1 -p "$DNS_PORT" db.tidb.lab CNAME 2>/dev/null | head -1 | sed 's/\.$//'
}

dns_resolve_a() {
    # Resolve db.tidb.lab via local CoreDNS — return A record (following CNAME)
    dig +short +tcp @127.0.0.1 -p "$DNS_PORT" db.tidb.lab A 2>/dev/null | tail -1
}

wait_for_dns() {
    # wait_for_dns <expected_cname> <timeout>
    local expected="$1"
    local timeout="${2:-30}"
    local elapsed=0

    echo -n "Waiting for DNS (db.tidb.lab → ${expected})"
    while (( elapsed < timeout )); do
        local resolved
        resolved=$(dns_resolve)
        if [[ "$resolved" == "$expected" ]]; then
            echo " ✓ (${elapsed}s)"
            return 0
        fi
        echo -n "."
        sleep 1
        (( elapsed++ ))
    done
    echo " ⚠ timeout (got: $(dns_resolve))"
    return 1
}

run_probe() {
    docker compose -f docker-compose.yaml --profile probe run --rm -T \
        -e DEDICATED_HOST -e DEDICATED_PORT -e DEDICATED_USER -e DEDICATED_PASSWORD \
        -e ESSENTIAL_HOST -e ESSENTIAL_PORT -e ESSENTIAL_USER -e ESSENTIAL_PASSWORD \
        probe "$@"
}

header() {
    echo ""
    echo "================================================================"
    echo "  $1"
    echo "================================================================"
    echo ""
}
