<!-- lab-meta
archetype: scripted-validation
status: released
products: [tidb, tiproxy, proxysql, haproxy]
-->

# Lab-08 — SQL Proxy Switchover: TiProxy vs ProxySQL vs HAProxy

**Goal:** Compare how three proxy architectures handle backend TiDB server
switchover from the application's perspective — measuring connection drops,
recovery time, and endpoint stability.

- **TiProxy** — TiDB-native proxy with graceful session migration
- **ProxySQL** — MySQL-protocol-aware proxy with connection pooling
- **HAProxy** — Traditional TCP proxy with health-check failover

## Context

TiDB Cloud Essential uses TiProxy as its SQL proxy layer. When a backend TiDB
server is taken offline (maintenance, scaling, crash), TiProxy should migrate
sessions gracefully without the app needing to know the endpoint changed.
ProxySQL understands the MySQL protocol and can pool/reuse connections but still
drops active sessions. HAProxy does TCP-level failover which drops existing
connections entirely.

This lab simulates that switchover locally to measure the differences across all
three proxy types.

## Tested Environment

- TiDB v8.5.4 (`pingcap/tidb:v8.5.4`)
- PD v8.5.4 (`pingcap/pd:v8.5.4`)
- TiKV v8.5.4 (`pingcap/tikv:v8.5.4`)
- TiProxy v1.3.0 (`pingcap/tiproxy:v1.3.0`)
- ProxySQL 2.7.1 (`proxysql/proxysql:2.7.1`)
- HAProxy 2.9 (`haproxy:2.9-alpine`)
- Python 3.10+ with pymysql
- Docker Desktop on macOS (arm64)

## Architecture

```text
                    ┌──────────┐
                    │    PD    │
                    └────┬─────┘
                         │
                    ┌────┴─────┐
                    │   TiKV   │
                    └────┬─────┘
                    ┌────┴─────┐
            ┌───────┤  tidb-1  ├───────┐
            │       │  :4001   │       │
            │       └──────────┘       │
            │            │             │
       ┌────┴─────┐ ┌────┴─────┐ ┌────┴─────┐
       │ TiProxy  │ │ ProxySQL │ │ HAProxy  │
       │  :6000   │ │  :6002   │ │  :6001   │
       └────┬─────┘ └────┬─────┘ └────┬─────┘
            │            │             │
            │       ┌────┴─────┐       │
            └───────┤  tidb-2  ├───────┘
                    │  :4002   │
                    └──────────┘
```

## Scenarios

- **S1 — Baseline**: Both proxies healthy, no switchover. Establishes latency
  baseline.
- **S2 — Switchover**: Stop `tidb-1` mid-test. Compare how each proxy handles
  the failover — session continuity, error count, recovery time.

## How to Run

### Prerequisites

```bash
pip install pymysql   # or: pip3 install pymysql
```

### Full run

```bash
./scripts/run-all.sh
```

### Individual steps

```bash
./scripts/step0-start.sh        # Start PD + TiKV + 2x TiDB + TiProxy + ProxySQL + HAProxy
./scripts/step1-baseline.sh     # Baseline probes (no switchover)
./scripts/step2-switchover.sh   # Stop tidb-1, observe failover
./scripts/stepN-cleanup.sh      # Tear everything down
```

### Manual probe

```bash
# Probe TiProxy only
python3 probe.py --target tiproxy --host 127.0.0.1 --port 6000 --duration 60

# Probe all three, save JSON
python3 probe.py \
    --target tiproxy --host 127.0.0.1 --port 6000 \
    --target proxysql --host 127.0.0.1 --port 6002 \
    --target haproxy --host 127.0.0.1 --port 6001 \
    --duration 30 --interval 0.5 --output results/manual.json
```

## Step 0 — Start Infrastructure

Brings up the full stack: PD, TiKV, 2x TiDB, TiProxy, ProxySQL, HAProxy.

```bash
./scripts/step0-start.sh
```

Verify:

```bash
# Direct backend access
mysql -h127.0.0.1 -P4001 -uroot -e "SELECT CONNECTION_ID(), @@hostname"
mysql -h127.0.0.1 -P4002 -uroot -e "SELECT CONNECTION_ID(), @@hostname"

# Through each proxy
mysql -h127.0.0.1 -P6000 -uroot -e "SELECT CONNECTION_ID(), @@hostname"  # TiProxy
mysql -h127.0.0.1 -P6002 -uroot -e "SELECT CONNECTION_ID(), @@hostname"  # ProxySQL
mysql -h127.0.0.1 -P6001 -uroot -e "SELECT CONNECTION_ID(), @@hostname"  # HAProxy

# HAProxy stats
open http://127.0.0.1:8404/stats
```

## Step 1 — Baseline Probes

Probes both proxies simultaneously for 30s with no disruption. Establishes
normal latency and confirms both proxies route correctly.

```bash
./scripts/step1-baseline.sh
```

## Step 2 — Switchover Test

Probes both proxies while `tidb-1` is stopped mid-test:

1. Probe for 10s (pre-switchover baseline)
2. `docker stop lab08-tidb-1` (trigger switchover)
3. Continue probing for 20s (observe failover)

```bash
./scripts/step2-switchover.sh
```

## Results Matrix

| Metric | TiProxy | ProxySQL | HAProxy | Notes |
|--------|---------|----------|---------|-------|
| Baseline success rate | 100% | 100% | 100% | All stable without disruption |
| Switchover success rate | 100% | 100% | 95% | HAProxy dropped 2 queries |
| Connection drops | 0 | 0 | 2 | ProxySQL rerouted transparently |
| Max query gap (seconds) | 0.51s | 0.51s | 11.51s | HAProxy gap = detect + reconnect |
| Failure window duration | 0s | 0s | 6.01s | HAProxy unreachable for 6s |
| Session preserved (conn_id) | Yes | No | No | Only TiProxy keeps the same conn_id |
| Backend switch detected | 0 | 1 | 1 | ProxySQL + HAProxy both switched backends |

## Analysis & Findings

- **TiProxy: zero disruption, session preserved.** No connection ID change, no
  backend switch visible to the app. TiProxy either migrated the session
  to tidb-2 or was already routed there. The app never noticed anything.

- **ProxySQL: zero disruption, but new connection.** Zero failed queries — ProxySQL's
  MySQL-protocol-aware monitoring detected the dead backend faster than HAProxy's
  TCP checks and transparently rerouted to tidb-2. However, the connection ID
  changed (no session migration). For stateless queries this is equivalent to
  TiProxy; for prepared statements or session state it would be different.

- **HAProxy: 6-second blackout.** TCP-level health check (`fall 2` at 2s intervals)
  took ~4s to detect the failure, plus reconnect overhead. During the window the
  app got `Lost connection to MySQL server during query` errors.

- **Three tiers of proxy intelligence:**
  1. TiDB-native (TiProxy) — session migration, zero visible disruption
  2. MySQL-aware (ProxySQL) — protocol-level failover, no query failures but new session
  3. TCP-level (HAProxy) — health check + reconnect, seconds of downtime

- **Implication for TiDB Cloud.** Essential tier uses TiProxy, giving apps
  transparent backend maintenance. For self-hosted deployments, ProxySQL is a
  strong alternative if TiProxy isn't available — it achieves comparable uptime
  through MySQL-aware connection management.

## Cleanup

```bash
./scripts/stepN-cleanup.sh
```

## References

- [TiProxy Documentation](https://docs.pingcap.com/tidb/stable/tiproxy-overview)
- [TiProxy Session Migration](https://docs.pingcap.com/tidb/stable/tiproxy-session-migration)
- [HAProxy MySQL Health Checks](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/health-checks/mysql/)
- [TiDB Cloud Essential Architecture](https://docs.pingcap.com/tidbcloud/tidb-cloud-intro)
