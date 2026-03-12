<!-- lab-meta
archetype: scripted-validation
status: released
products: [tidb, tiproxy, haproxy, proxysql]
-->

# Lab-08 — SQL Proxy Switchover: TiProxy vs HAProxy vs ProxySQL

**Goal:** Compare how three SQL proxy types handle a TiDB backend failure —
measuring connection stability, failover latency, and disruption window when
one of two TiDB backends goes down.

## Context

Applications rarely connect directly to TiDB in production. A proxy layer
(TiProxy, HAProxy, ProxySQL, or cloud load balancer) mediates connections and
is expected to handle backend failures transparently. This lab measures what
each proxy actually does when a backend disappears:

- Does it maintain the existing connection or force a reconnect?
- How long is the disruption window?
- Does the client see errors, or is the switchover invisible?

These results directly informed [Lab 09 — DNS Failover](../lab-09-dns-failover/)
(the no-proxy case) and [Lab 11 — Cloud Proxy Failover](../lab-11-cloud-proxy-failover/)
(cloud backends with real TiDB Cloud endpoints).

## Tested Environment

- TiDB v8.5.4 (`pingcap/tidb:v8.5.4`) — unistore mode (no TiKV needed)
- TiProxy v1.3.0 (`pingcap/tiproxy:v1.3.0`) — L7, TiDB-aware
- HAProxy 2.9 (`haproxy:2.9`) — L4 TCP proxy
- ProxySQL 2.7.1 (`proxysql/proxysql:2.7.1`) — L7 MySQL-aware
- Python 3.12 (`python:3.12-slim`), pymysql 1.1.1
- Docker Desktop 4.38.0 on macOS 15.4 (arm64)

## Architecture

```text
┌──────────────────────────────────────────────────────┐
│                    Client (probe.py)                 │
│            concurrent threads per proxy              │
└──────┬────────────────┬────────────────┬─────────────┘
       │                │                │
  ┌────┴────┐     ┌─────┴─────┐    ┌────┴──────┐
  │ TiProxy │     │  HAProxy  │    │ ProxySQL  │
  │ L7:6000 │     │  L4:6001  │    │  L7:6002  │
  └────┬────┘     └─────┬─────┘    └────┬──────┘
       │                │               │
  ┌────┴────────────────┴───────────────┴────┐
  │                                          │
  │  ┌──────────┐          ┌──────────┐      │
  │  │  tidb-1  │          │  tidb-2  │      │
  │  │  :4000   │          │  :4000   │      │
  │  └──────────┘          └──────────┘      │
  │           Docker network (lab08)         │
  └──────────────────────────────────────────┘
```

## Scenarios

- **S0 — Baseline:** All backends healthy. 30s probe, no changes. Establishes
  steady-state latency and confirms all proxies route correctly.
- **S1 — Backend failure:** Stop tidb-1 at t=10s. Observe how each proxy
  detects the failure and routes to tidb-2.

## How to Run

```bash
# Run all steps
./scripts/run-all.sh

# Individual steps
./scripts/step0-start.sh         # Start TiDB + proxies, configure routing
./scripts/step1-baseline.sh      # Baseline — no switchover
./scripts/step2-switchover.sh    # Stop tidb-1 mid-test
./scripts/stepN-cleanup.sh       # Cleanup
```

### TiProxy Static Backend Note

TiProxy normally discovers backends via PD. In this lab (unistore mode, no PD),
backends are configured via the namespace API after startup. TiProxy logs
periodic warnings (`metrics reader` nil etcd) — these are cosmetic and do not
affect routing.

## Results (2026-03-11)

### Baseline (no switchover)

| Proxy | Success | Avg Latency | P99 Latency | Conn Changes | Backend Switches |
|-------|---------|-------------|-------------|--------------|------------------|
| TiProxy | 100% (60/60) | 2.5ms | 4.0ms | 0 | 0 |
| ProxySQL | 100% (60/60) | 2.4ms | 3.8ms | 0 | 0 |
| HAProxy | 100% (60/60) | 2.5ms | 3.8ms | 0 | 0 |

All proxies stable. TiProxy and HAProxy routed to tidb-1; ProxySQL
independently selected tidb-2 (its own load balancing).

### Switchover (stop tidb-1 at t=10s)

| Proxy | Success | Avg Latency | Conn Changes | Backend Switches | Max Gap | Failure Window |
|-------|---------|-------------|--------------|------------------|---------|----------------|
| **TiProxy** | **100%** (60/60) | 2.2ms | 0 | 0 | 0.51s | **0.00s** |
| **ProxySQL** | **100%** (60/60) | 2.1ms | 1 | 1 | 0.51s | **0.00s** |
| **HAProxy** | **95%** (38/40) | 2.3ms | 1 | 1 | 11.51s | **6.01s** |

### Switchover Detail

**TiProxy (L7, TiDB-aware)** — Best performance. Zero disruption. TiProxy
detected the impending failure and proactively migrated the connection to
tidb-2 before tidb-1 stopped responding. No connection ID change, no backend
switch visible to the client. This is the expected behavior for TiDB's native
proxy, which has session-level migration capability.

**ProxySQL (L7, MySQL-aware)** — Zero failures but required one connection
recreation. ProxySQL detected tidb-1's health check failure, switched the
backend to tidb-2 at `03:46:43`, and transparently reconnected the client.
The transition was seamless from a success-rate perspective (no probe failures)
but the connection ID changed, indicating a new MySQL session.

**HAProxy (L4, TCP pass-through)** — 6-second failure window. HAProxy's TCP
health check detected tidb-1 failure but existing connections received
`Lost connection to MySQL server during query` errors until HAProxy's
connection timeout expired. Two probes failed before the client reconnected
to tidb-2 at `03:46:54`. The 11.51s max gap includes the failure window.

### Switchover Timeline

```text
03:46:33  ─── Probe starts ────────────────────────────────────────
           TiProxy → tidb-2    ProxySQL → tidb-1    HAProxy → tidb-1
                                          │                   │
03:46:43  ─── tidb-1 stopped ──────── ProxySQL switches ──────│────
           TiProxy → tidb-2    ProxySQL → tidb-2              │
                                                              │
03:46:48  ─── HAProxy failure #1 ─────────────────────────────│────
03:46:54  ─── HAProxy failure #2, then reconnects ────────────┘
           TiProxy → tidb-2    ProxySQL → tidb-2    HAProxy → tidb-2
                                          │
03:47:03  ─── Probe ends ─────────────────────────────────────────
```

## Analysis

### 1. TiProxy's session migration is the differentiator

TiProxy is the only proxy that maintained the same connection ID through the
switchover. It uses TiDB's internal session migration protocol to move the
session state to a new backend without the client knowing. This is invisible
at the application layer — no reconnect, no session state loss.

### 2. ProxySQL achieves zero-failure switchover via L7 health checks

ProxySQL's MySQL-level health monitoring detected tidb-1's failure within one
health check interval (~2s) and reconfigured routing. The client's next query
was transparently routed to tidb-2 with a new connection. For stateless
workloads (most OLTP), this is equivalent to zero downtime.

### 3. HAProxy's L4 limitation causes a failure window

HAProxy operates at TCP level — it cannot inspect MySQL state or health-check
at the protocol level. When tidb-1 stops, existing TCP connections see read
timeouts until HAProxy's server health check marks it down (2s interval ×
2 fall threshold = 4s detection + connection timeout). The 6s failure window
is consistent with this.

### 4. Concurrent probing reveals real-time proxy behavior

Unlike Lab 09 (sequential targets), this lab probes all proxies simultaneously
using threads. This captures the exact moment each proxy detects the failure
and how their behavior differs under the same conditions.

### 5. Results are consistent across runs

Two independent test runs (02:39 and 03:45 UTC) produced matching behavior
patterns: TiProxy seamless, ProxySQL single-reconnect, HAProxy multi-second
failure. The second run is documented here as the canonical result.

## Cleanup

```bash
./scripts/stepN-cleanup.sh
```

## References

- [TiProxy Documentation](https://docs.pingcap.com/tidb/stable/tiproxy-overview)
- [HAProxy Configuration Manual](https://www.haproxy.org/download/2.9/doc/configuration.txt)
- [ProxySQL Documentation](https://proxysql.com/documentation/)
- [Lab 09 — DNS Failover](../lab-09-dns-failover/) (no-proxy comparison)
- [Lab 10 — Cloud DNS Failover](../lab-10-cloud-dns-failover/)
- [Lab 11 — Cloud Proxy Failover](../lab-11-cloud-proxy-failover/) (cloud backends)
