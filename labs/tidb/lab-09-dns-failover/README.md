<!-- lab-meta
archetype: scripted-validation
status: released
products: [tidb, coredns]
-->

# Lab-09 — DNS Failover: Client Behavior During Endpoint Resolution Changes

**Goal:** Measure how MySQL client libraries handle DNS resolution changes when a
TiDB endpoint's IP address changes — simulating what happens during cloud
provider failover, migration, or endpoint rotation without a proxy layer.

## Context

In Lab 08 we tested proxy-mediated switchover where the app connects to a stable
proxy endpoint. This lab tests the other case: **no proxy**, the DNS record
itself changes (e.g., a cloud provider rotates the IP behind a hostname). This
happens in:

- TiDB Cloud endpoint migration (Dedicated to Essential, region failover)
- AWS RDS failover (CNAME flip to standby)
- Manual DNS-based load balancing (Route53 weighted/failover records)

Key questions:
- How long do clients cache the old IP after a DNS change?
- Does TTL=0 actually help?
- Do common MySQL drivers (pymysql, Go sql, JDBC) reconnect to the new IP?
- What's the total disruption window from DNS flip to successful query?

## Evolution Plan

This lab starts local (CoreDNS + Docker) then evolves:

1. **Phase 1 (local):** CoreDNS + 2x TiDB unistore — test DNS TTL and client
   resolver behavior in isolation
2. **Phase 2 (AWS):** Replace one backend with AWS RDS MySQL or Aurora — test
   real DNS propagation with Route53
3. **Phase 3 (TiDB Cloud):** Replace backends with TiDB Cloud Essential/Premium
   endpoints — test actual cloud failover behavior with real TLS and gateways

## Tested Environment

- TiDB v8.5.4 (`pingcap/tidb:v8.5.4`) — unistore mode (no TiKV needed)
- CoreDNS 1.12.0 (`coredns/coredns:1.12.0`) via Alpine 3.20 (`alpine:3.20`)
- Python 3.12 (`python:3.12-slim`), pymysql 1.1.1
- Docker Desktop 4.38.0 on macOS 15.4 (arm64)
- mysql client (for `wait_for_port` health checks)

## Architecture

### Phase 1 — Local

```text
┌──────────────────────────────────┐
│          CoreDNS :53             │
│   tidb.lab → tidb-1 (initial)   │
│   tidb.lab → tidb-2 (after flip)│
└──────────┬───────────────────────┘
           │ DNS resolution
      ┌────┴─────┐
      │  probe   │  ← connects to tidb.lab:4000
      └────┬─────┘
      ┌────┴─────┐    ┌──────────┐
      │  tidb-1  │    │  tidb-2  │
      │  :4000   │    │  :4000   │
      └──────────┘    └──────────┘
```

### Phase 2+ — Cloud Backends

```text
┌──────────────────────────────────┐
│     Route53 / Cloud DNS          │
│   endpoint → backend-a (before)  │
│   endpoint → backend-b (after)   │
└──────────┬───────────────────────┘
           │
      ┌────┴─────┐
      │  probe   │  ← connects to cloud endpoint
      └────┬─────┘
           │
    ┌──────┴──────────────────┐
    │  TiDB Cloud / RDS / ..  │
    └─────────────────────────┘
```

## Scenarios (Phase 1)

- **S1 — TTL=1, immediate flip**: CoreDNS serves A record with minimum TTL
  (requested TTL=0 is clamped to 1 by the `file` plugin), flip mid-test.
  Expect: client resolves new IP on next connection attempt.
- **S2 — TTL=30, cached flip**: CoreDNS serves TTL=30, flip mid-test. Expect:
  client uses stale IP for up to 30s.

### Future Scenarios

- **S3 — Persistent connection**: Keep one connection alive across DNS flip.
  Expect: existing connection stays on old backend; new connections go to new IP.
- **S4 — Connection pool behavior**: Test with connection pooling (ProxySQL or
  app-level). Expect: pool gradually drains old connections.

## How to Run

```bash
# Phase 1 — local only
./scripts/run-all.sh

# Individual steps
./scripts/step0-start.sh          # Start CoreDNS + 2x TiDB unistore
./scripts/step1-baseline.sh       # Probe via DNS name, no flip
./scripts/step2-dns-flip-ttl1.sh  # Flip DNS record (TTL=1), observe
./scripts/step3-dns-flip-ttl30.sh # Flip DNS record (TTL=30), observe
./scripts/stepN-cleanup.sh
```

## Results (2026-03-11)

### Summary

| Scenario | TTL | Probes | Success | Disruption | New IP after | Notes |
|----------|-----|--------|---------|-----------|-------------|-------|
| S1 — TTL=1 flip | 1 (CoreDNS min) | 59 | 100% (59/59) | **0.00s** | Same probe cycle | DNS-aware reconnect |
| S2 — TTL=30 flip | 30 | 108 | 100% (108/108) | **0.00s** | Same probe cycle | Identical to S1 |
| Baseline (no flip) | 5 | 59 | 100% (59/59) | N/A | N/A | Steady state |
| S3 — Persistent conn | — | — | — | — | — | Not tested |
| S4 — Connection pool | — | — | — | — | — | Not tested |

### Latency

| Scenario | Avg latency | Max latency | Reconnect cost |
|----------|-------------|-------------|----------------|
| Baseline | 10.37ms | 19.30ms | N/A |
| S1 (TTL=1) | 11.67ms | 17.74ms | ~12ms (within probe cycle) |
| S2 (TTL=30) | 11.66ms | 16.28ms | ~12ms (within probe cycle) |

### DNS Flip Detail

Both flip scenarios detected the DNS change at probe #20 (~10s in, matching `PRE_FLIP=10`):

- **S1 (TTL=1):** Old IP at `06:15:34.279`, new IP at `06:15:34.796` (0.52s = one probe interval). Zero failures. Backend confirmed changed via `@@hostname` (container ID `619e3eefef5f` → `376faa7bcffa`).
- **S2 (TTL=30):** Old IP at `06:16:08.067`, new IP at `06:16:08.584` (0.52s). Zero failures. Identical behavior to S1.

## Analysis & Findings

### 1. TTL has no observable effect

Both TTL=1 and TTL=30 show identical failover behavior. The probe uses `dig` for DNS resolution on every cycle, and `dig` does not cache — it queries CoreDNS directly. The TTL value only matters for clients or resolvers that maintain a cache (e.g., system resolver, Java DNS cache, Go's `net.Resolver`). **This lab does not test TTL-based caching** because the probe bypasses it.

> **Note:** CoreDNS `file` plugin clamps TTL=0 to TTL=1. S1 requests TTL=0 but serves TTL=1.

### 2. DNS-aware reconnection enables zero downtime

The probe resolves DNS on every cycle and triggers a reconnection when the resolved IP changes. This is why failover is seamless — the client detects the new IP and opens a new TCP connection within the same probe cycle (~12ms). The existing connection is closed, not reused.

### 3. Persistent connection (S3) and connection pool (S4) not tested

The probe's architecture (DNS check + reconnect on change) means it never tests what happens to an existing TCP connection when DNS changes underneath it. True S3 testing would require keeping the connection alive without DNS checking — the TCP connection would survive the flip (since TCP is IP-based, not hostname-based) and the client would keep talking to the old backend until the connection breaks or is recycled.

S4 (connection pool) would require multiple concurrent connections with pool-level health checking. The single-connection probe can't test this.

### 4. Probe targets are tested sequentially

When multiple `--target` flags are passed, the probe runs them sequentially (not in parallel). Each target completes its full `--duration` before the next starts. This means multi-target results cannot be compared for simultaneous behavior — only for individual endpoint characteristics.

### 5. Local latency is sub-millisecond for the query itself

The ~10ms average latency includes DNS resolution via `dig` subprocess + TCP connect + MySQL query. The query portion alone is <1ms (Docker bridge network). This baseline is useful for isolating DNS/connection overhead.

### 6. Backend verification works

`SELECT @@hostname` returns the container ID, providing ground-truth confirmation that the probe is talking to a different TiDB instance after the flip. This pattern was adopted by [Lab 10 — Cloud DNS Failover](../lab-10-cloud-dns-failover/) and [Lab 11 — Cloud Proxy Failover](../lab-11-cloud-proxy-failover/), which use `VERSION()` to distinguish cloud tiers.

## Cleanup

```bash
./scripts/stepN-cleanup.sh
```

## References

- [CoreDNS Manual](https://coredns.io/manual/toc/)
- [CoreDNS auto plugin](https://coredns.io/plugins/auto/) — zone file reloading
- [pymysql connection handling](https://pymysql.readthedocs.io/)
- [MySQL Connector/J DNS caching](https://dev.mysql.com/doc/connector-j/8.0/en/)
- [AWS Route53 Failover Routing](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-policy-failover.html)
- Lab 08 — SQL Proxy Switchover (proxy-mediated comparison)
