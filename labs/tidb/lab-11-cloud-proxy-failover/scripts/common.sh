# Sourced by step scripts — not executed directly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$LAB_DIR"

# Load .env
if [[ -f .env ]]; then
    set -a
    # shellcheck source=/dev/null
    source .env
    set +a
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
RESULTS_DIR="$LAB_DIR/results"
mkdir -p "$RESULTS_DIR"

# Proxy ports
HAPROXY_PORT=6001
PROXYSQL_PORT=6033
PROXYSQL_ADMIN=6032

# Probe defaults
PROBE_DURATION="${PROBE_DURATION:-60}"
PROBE_INTERVAL="${PROBE_INTERVAL:-2}"

# --- Functions ---

haproxy_set_backend() {
    local host="$1"
    local port="${2:-4000}"

    cat > "$LAB_DIR/conf/haproxy/haproxy.cfg" <<EOF
global
    log stdout format raw local0
    maxconn 256

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 10s
    timeout client  60s
    timeout server  60s

frontend mysql_front
    bind *:6001
    default_backend tidb_back

backend tidb_back
    balance roundrobin
    server backend1 ${host}:${port}
EOF

    # Hard restart to force connection reset (L4 requires this)
    sudo pkill haproxy 2>/dev/null || true
    sleep 0.5
    sudo haproxy -f "$LAB_DIR/conf/haproxy/haproxy.cfg" -D
    echo "HAProxy → ${host}:${port} (restarted)"
}

proxysql_set_backend() {
    local host="$1"
    local port="${2:-4000}"

    mysql -h127.0.0.1 -P"${PROXYSQL_ADMIN}" -uradmin -pradmin -e "
        UPDATE mysql_servers SET hostname='${host}', port=${port} WHERE hostgroup_id=1;
        LOAD MYSQL SERVERS TO RUNTIME;
        SAVE MYSQL SERVERS TO DISK;
    " 2>/dev/null
    echo "ProxySQL → ${host}:${port}"
}

proxysql_init_config() {
    # Write proxysql.cnf with real credentials (before first start)
    sed -e "s/PROXY_USER/${PROXY_USER}/g" \
        -e "s/PROXY_PASSWORD/${PROXY_PASSWORD}/g" \
        -e "s/DEDICATED_HOST/${DEDICATED_HOST}/g" \
        "$LAB_DIR/conf/proxysql/proxysql.cnf.tmpl" \
        > "$LAB_DIR/conf/proxysql/proxysql.cnf"
}

run_probe() {
    python3 "$LAB_DIR/probe.py" "$@"
}

header() {
    echo ""
    echo "================================================================"
    echo "  $1"
    echo "================================================================"
    echo ""
}
