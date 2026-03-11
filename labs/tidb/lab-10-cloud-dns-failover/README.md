<!-- lab-meta
archetype: scripted-validation
status: released
products: [tidb, tidb-cloud]
-->

# Lab 10: Cloud DNS Failover (Dedicated ↔ Essential)

Test DNS-based endpoint switching against real TiDB Cloud clusters to validate that DNS failover works for tier migrations.

## Architecture

```text
┌─────────────────────────────────────────────┐
│  Local Docker                               │
│                                             │
│  ┌──────────┐    ┌──────────────────────┐   │
│  │ CoreDNS  │    │ Probe (Python 3.12)  │   │
│  │          │◄───│  pymysql + dnspython  │   │
│  │ db.tidb. │    │  TLS + SNI           │   │
│  │ lab zone │    └────────┬─────────────┘   │
│  └────┬─────┘             │                 │
│       │                   │ TLS :4000       │
│       │ forward . 8.8.8.8 │                 │
└───────┼───────────────────┼─────────────────┘
        │                   │
        ▼                   ▼
┌───────────────┐   ┌──────────────────┐
│ Public DNS    │   │ TiDB Cloud       │
│ (resolve      │   │                  │
│  cloud CNAME) │   │ Dedicated ←──┐   │
│               │   │              │   │
└───────────────┘   │ Essential ←──┘   │
                    │  (DNS flip)      │
                    └──────────────────┘
```

**How it works:**
1. Probe resolves `db.tidb.lab` via local CoreDNS
2. CoreDNS returns a CNAME pointing to a cloud endpoint (e.g., `gateway01.us-east-1.prod.aws.tidbcloud.com`)
3. CoreDNS follows the CNAME chain via `forward . 8.8.8.8` to get the IP
4. Probe connects to the cloud endpoint using TLS with correct SNI
5. Credentials are selected based on the CNAME target hostname

**DNS flip** = swap the CNAME target in CoreDNS zone file + restart. No AWS Route53 or VPC changes.

## Tested Environment

- Python 3.12 (`python:3.12-slim`)
- CoreDNS 1.12.0 (`coredns/coredns:1.12.0`)
- Alpine 3.20 (`alpine:3.20`)
- pymysql 1.1.1, dnspython 2.7.0
- Docker Desktop 4.38.0 on macOS 15.4 (arm64)
- TiDB Cloud Dedicated v8.5.3, Essential v8.5.3-serverless

## Prerequisites

- Docker Desktop
- MySQL client (`brew install mysql-client`)
- `dig` (`brew install bind` or `dnsutils`)
- TiDB Cloud credentials for both clusters (Dedicated + Essential)
- Network access to TiDB Cloud endpoints (port 4000)

## Setup

```bash
cp .env.example .env
# Fill in DEDICATED_HOST, DEDICATED_PASSWORD, ESSENTIAL_HOST, ESSENTIAL_USER, ESSENTIAL_PASSWORD
```

## Quick Start

```bash
# Run all steps
./scripts/run-all.sh

# Or step by step:
./scripts/step0-smoke-test.sh   # Verify auth + connectivity
./scripts/step1-start.sh        # Start CoreDNS → Dedicated
./scripts/step2-baseline.sh     # Probe baseline (no flip)
./scripts/step3-dns-flip.sh     # Flip to Essential, observe
./scripts/stepN-cleanup.sh      # Stop containers
```

## What to Look For

### Baseline (step 2)
- All probes should show `[OK]` with the Dedicated cluster name
- Steady DNS resolution time and query latency

### DNS Flip (step 3)
- `DNS_FLIP` event in probe output when CNAME changes
- Brief failure window during reconnection with new credentials
- `[R]` marker when probe establishes new connection to Essential
- Different `cluster_name` after flip

### Results

JSONL probe logs and JSON summaries are saved to `results/`:
- `baseline-*.jsonl` — per-probe records
- `baseline-*-summary.json` — aggregate metrics
- `failover-*.jsonl` / `failover-*-summary.json` — flip test

Key metrics:
- **dns_ms** — DNS resolution time (includes CNAME + A resolution)
- **connect_ms** — TLS connection setup time to cloud endpoint
- **query_ms** — MySQL query round-trip
- **failure_windows** — gaps where probe couldn't reach either endpoint

## Key Differences from Lab 09

| Aspect | Lab 09 (Local) | Lab 10 (Cloud) |
|--------|----------------|-----------------|
| Backends | Local Docker TiDB | TiDB Cloud clusters |
| DNS record | A record | CNAME → cloud endpoint |
| TLS | None | Required (TLS + SNI) |
| Credentials | Single (root/empty) | Per-endpoint (different users) |
| Latency | <1ms | ~50-200ms (cloud RTT) |
| Detection | IP change | CNAME change |

## Results (2026-03-11)

### Baseline: 30/30 OK (100%)
- DNS resolution: ~18-50ms (CNAME + A via CoreDNS → 8.8.8.8)
- Initial connection: ~280ms (TCP + MySQL STARTTLS handshake)
- Query latency: ~35ms steady state
- CNAME target stable, multiple IPs returned (load-balanced cloud endpoint)

### DNS Flip: 30/30 OK (100%), zero-downtime failover
- Probes 1-8: Dedicated cluster (`8.0.11-TiDB-v8.5.3`)
- Probe 9: **DNS_FLIP detected** — seamless switch to Essential, reconnect `[R]`
- Probes 10-30: Essential cluster (`8.0.11-TiDB-v8.5.3-serverless`)
- Failover time: **0.00s** (first success immediately on same probe cycle as detection)
- Reconnection cost: ~336ms (new connection to Essential endpoint)
- **Zero failure probes** during the entire flip

### Key Findings
1. **VERSION() distinguishes tiers**: Dedicated returns `v8.5.3`, Essential returns `v8.5.3-serverless`
2. **CNAME-based switching works**: CoreDNS CNAME flip + restart propagates in <2s
3. **Credential switching works**: Probe detects CNAME change, selects correct user/password
4. **Cloud TLS**: Both endpoints use MySQL STARTTLS (negotiated), not direct TLS wrapping
5. **IP instability is normal**: Cloud endpoints return multiple IPs per query (load balancer), but CNAME target is the stable discriminator

## Safety

- No Route53 changes — local CoreDNS only
- No VPC/DNS infrastructure changes
- Essential cluster is disposable — delete after test
- Credentials in `.env` only (gitignored)

## References

- [TiDB Cloud TLS for Dedicated](https://docs.pingcap.com/tidbcloud/tidb-cloud-tls-connect-to-dedicated/)
- [TiDB Cloud TLS for Essential](https://docs.pingcap.com/tidbcloud/secure-connections-to-serverless-clusters/)
- [CoreDNS file plugin](https://coredns.io/plugins/file/)
- [pymysql documentation](https://pymysql.readthedocs.io/)
- [dnspython documentation](https://dnspython.readthedocs.io/)
