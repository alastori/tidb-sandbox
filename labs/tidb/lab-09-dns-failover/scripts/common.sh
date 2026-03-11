# Common utilities for Lab 09 — DNS Failover
# Sourced by step scripts — not executed directly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"

# Load .env if present
ENV_FILE="${ENV_FILE:-${LAB_DIR}/.env}"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Timestamp (UTC ISO format)
TS="${TS:-$(date -u +%Y%m%dT%H%M%SZ)}"

# Results directory
RESULTS_DIR="${RESULTS_DIR:-${LAB_DIR}/results}"
mkdir -p "${RESULTS_DIR}"

# Network
TIDB1_IP="172.30.0.21"
TIDB2_IP="172.30.0.22"
DNS_IP="172.30.0.10"
DNS_PORT=5300

# Ports (host-side)
TIDB1_PORT=4001
TIDB2_PORT=4002

# Probe settings
PROBE_DURATION="${PROBE_DURATION:-30}"
PROBE_INTERVAL="${PROBE_INTERVAL:-0.5}"

# Health check
MAX_RETRIES="${MAX_RETRIES:-30}"
RETRY_INTERVAL="${RETRY_INTERVAL:-2}"

# DNS server (internal = container network, external = host access)
DNS_SERVER_INTERNAL="172.30.0.10:53"

# CoreDNS zone file
ZONE_FILE="${LAB_DIR}/conf/coredns/db.lab"

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------

find_mysql() {
    if command -v mysql &>/dev/null; then
        echo "mysql"
    elif [ -x "/opt/homebrew/opt/mysql-client/bin/mysql" ]; then
        echo "/opt/homebrew/opt/mysql-client/bin/mysql"
    elif [ -x "/usr/local/opt/mysql-client/bin/mysql" ]; then
        echo "/usr/local/opt/mysql-client/bin/mysql"
    else
        echo ""
    fi
}

wait_for_port() {
    local port=$1
    local label=${2:-"service"}
    local retries=0

    echo "Waiting for ${label} on port ${port}..."
    local mysql_bin
    mysql_bin=$(find_mysql)
    if [[ -z "$mysql_bin" ]]; then
        echo "ERROR: mysql client not found"
        return 1
    fi

    while [ $retries -lt $MAX_RETRIES ]; do
        if "$mysql_bin" -h127.0.0.1 -P"$port" -uroot -e "SELECT 1" &>/dev/null; then
            echo "${label} is ready!"
            return 0
        fi
        retries=$((retries + 1))
        echo "  Attempt ${retries}/${MAX_RETRIES}..."
        sleep $RETRY_INTERVAL
    done
    echo "ERROR: ${label} failed to become ready on port ${port}"
    return 1
}

# Flip DNS: update zone file to point tidb.lab at a new IP
# Usage: dns_flip <target_ip> <ttl>
dns_flip() {
    local target_ip=$1
    local ttl=${2:-1}
    # CoreDNS file plugin requires TTL >= 1
    [[ "$ttl" -lt 1 ]] && ttl=1
    # Serial must fit in 32-bit uint (max 4294967295); epoch seconds works until 2106
    local serial
    serial=$(date +%s)

    local zone_content
    zone_content=$(cat <<ZONE
\$ORIGIN lab.
\$TTL ${ttl}

@     IN  SOA  ns.lab. admin.lab. (
              ${serial} ; serial
              3600      ; refresh
              600       ; retry
              86400     ; expire
              ${ttl} )  ; minimum

@     IN  NS   ns.lab.
ns    IN  A    172.30.0.10
tidb  IN  A    ${target_ip}
ZONE
)

    # Write to host file (used as build context for Dockerfile.coredns + docker cp source)
    printf '%s\n' "$zone_content" > "${ZONE_FILE}"

    # Copy zone file into container and restart CoreDNS to guarantee pickup
    # CoreDNS file plugin's mtime-based reload is unreliable with docker cp/exec on macOS
    if docker inspect lab09-coredns --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
        docker cp "${ZONE_FILE}" lab09-coredns:/zones/db.lab 2>/dev/null || true
        docker restart lab09-coredns >/dev/null 2>&1
        sleep 1
        echo "DNS flipped: tidb.lab → ${target_ip} (TTL=${ttl})"
    else
        echo "DNS flipped: tidb.lab → ${target_ip} (TTL=${ttl}, host-only)"
    fi
}

# Verify DNS resolution — prefer container-internal check (avoids macOS port forwarding issues)
dns_resolve() {
    # Try resolving from inside the CoreDNS container first (most reliable)
    local result
    result=$(docker exec lab09-coredns nslookup tidb.lab 127.0.0.1 2>/dev/null \
        | awk '/^Address:/ && !/127\.0\.0\.1/ {print $2}' | head -1)
    if [[ -n "$result" ]]; then
        echo "$result"
        return
    fi
    # Fallback to host-side dig (for before container starts)
    dig +short +tcp @127.0.0.1 -p $DNS_PORT tidb.lab A 2>/dev/null
}

# Wait for CoreDNS to pick up zone change (reload checks every 2s)
dns_reload() {
    sleep 3
}

# Force CoreDNS to reload by restarting the container process
# Use between steps (not during probes) when file-based reload is unreliable
dns_force_reload() {
    echo "  Restarting CoreDNS to force zone reload..."
    docker restart lab09-coredns >/dev/null 2>&1
    sleep 2
}

# Wait until CoreDNS serves the expected IP (handles Docker volume propagation delay)
# Usage: wait_for_dns <expected_ip> [timeout_seconds]
wait_for_dns() {
    local expected_ip=$1
    local timeout=${2:-30}
    local elapsed=0
    echo "  Waiting for CoreDNS to serve ${expected_ip}..."
    while [ $elapsed -lt $timeout ]; do
        local resolved
        resolved=$(dns_resolve)
        if [[ "$resolved" == "$expected_ip" ]]; then
            echo "  CoreDNS confirmed: tidb.lab → ${resolved} (${elapsed}s)"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo "  WARNING: CoreDNS still serving $(dns_resolve) after ${timeout}s (expected ${expected_ip})"
    return 1
}

# Run probe inside Docker (macOS can't route to container IPs)
# Usage: run_probe [probe.py args...]
run_probe() {
    docker compose -f "${LAB_DIR}/docker-compose.yaml" --profile probe \
        run --rm -T probe "$@"
}

export SCRIPT_DIR LAB_DIR TS RESULTS_DIR
export TIDB1_IP TIDB2_IP DNS_IP DNS_PORT DNS_SERVER_INTERNAL
export TIDB1_PORT TIDB2_PORT
export PROBE_DURATION PROBE_INTERVAL
export MAX_RETRIES RETRY_INTERVAL ZONE_FILE
