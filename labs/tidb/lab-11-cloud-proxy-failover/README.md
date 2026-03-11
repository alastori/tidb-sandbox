<!-- lab-meta
archetype: scripted-validation
status: released
products: [tidb, tidb-cloud]
-->

# Lab 11: Cloud Proxy Failover (HAProxy / ProxySQL)

Test proxy-based failover between TiDB Cloud Dedicated and Essential clusters using external proxies on EC2.

## Architecture

```text
Client → [EC2 Proxy] → TiDB Cloud
              ├── HAProxy  (L4 TCP, port 6001)
              └── ProxySQL (L7 MySQL, port 6033)
```

**HAProxy** operates at L4 (TCP) — passes through TLS end-to-end. Client initiates MySQL STARTTLS directly with TiDB Cloud. Failover requires process restart (kills existing connections).

**ProxySQL** operates at L7 (MySQL) — terminates the MySQL protocol and manages backend connections independently. Uses `use_ssl=1` for backend TLS. Failover via runtime admin SQL — zero client disruption.

## Tested Environment

- Amazon Linux 2023 (AL2023, arm64) on EC2 t4g.small, us-east-1
- HAProxy 2.4.22 (`dnf install haproxy`)
- ProxySQL 2.7.1 (AlmaLinux 9 aarch64 RPM)
- Python 3.9 (AL2023 default), pymysql 1.1.1
- TiDB Cloud Dedicated v8.5.3, Essential v8.5.3-serverless
- TiProxy v1.3.0, v1.3.2, v1.4.0-beta.1-nightly (via tiup)

## Prerequisites

1. **EC2 instance** (t4g.small, Amazon Linux 2023) in the same region as TiDB Cloud clusters
2. **Packages:** `haproxy`, `proxysql`, `mariadb105` (mysql client), `python3-pip`, `pymysql`
3. **TiDB Cloud clusters:**
   - Dedicated cluster with public endpoint enabled
   - Essential (Serverless) cluster
   - Same user/password on both (prefix username, e.g., `3HeeAGkLDr83GqD.root`)
4. **IP access list:** Add EC2 public IP to Dedicated cluster's IP access list (Networking → Edit IP Address)
5. Copy `.env.example` to `.env` and fill in endpoints + credentials

### Unified Credentials

Create the same user on both clusters. TiDB Cloud Dedicated pre-creates the prefix user — just set its password with `ALTER USER`. Essential creates it during cluster setup.

## Results (2026-03-11, us-east-1)

### HAProxy (L4 TCP)

| Metric | Baseline | Failover |
|--------|----------|----------|
| Success rate | 100% (15/15) | 96.7% (29/30) |
| Avg query latency | 1.8ms | — |
| Failures during switch | 0 | 1 |
| Failure window | — | 2.0s |
| Reconnect time | — | 777ms |

**Behavior:** HAProxy restart kills existing TCP connections. Client sees "Lost connection" on the active query, reconnects to new backend on next cycle. The 777ms reconnect includes TLS handshake to Essential.

### ProxySQL (L7 MySQL)

| Metric | Baseline | Failover |
|--------|----------|----------|
| Success rate | 100% (15/15) | **100% (30/30)** |
| Avg query latency | 1.4ms | — |
| Failures during switch | 0 | **0** |
| Failure window | — | **none** |
| Switch latency | — | 30ms |

**Behavior:** ProxySQL runtime reconfiguration via admin SQL. The backend swap is transparent — ProxySQL establishes a new backend connection and routes the next query through it. Client sees a 30ms latency blip on the switch cycle, then stable at ~3.9ms.

### TiProxy (L7 TiDB — static mode, Dedicated only)

| Metric | Baseline |
|--------|----------|
| Success rate | 100% (15/15) |
| Avg query latency | 1.9ms |
| Failover | Not functional (see TiProxy section) |

### Latency by Tier

| Tier | HAProxy (L4+TLS) | ProxySQL (L7) | TiProxy (L7) |
|------|-------------------|---------------|--------------|
| Dedicated | ~1.5ms | ~1.4ms | ~1.9ms |
| Essential | ~3.4ms | ~3.9ms | N/A (TLS broken) |

Essential adds ~2ms latency due to the serverless routing layer.

## TiProxy: Partial Static Mode (Workaround Found)

TiProxy can work without PD using a **two-step namespace API** workaround, but with significant limitations:

### What works

- **Static routing:** Set `pd-addrs = ""` in config, then register backends via API:
  ```bash
  curl -X PUT http://localhost:3080/api/admin/namespace/default \
    -H 'Content-Type: application/json' \
    -d '{"namespace":"default","frontend":{"user":""},"backend":{"instances":["host:4000"],"security":{}}}'
  curl -X POST http://localhost:3080/api/admin/namespace/commit  # REQUIRED — triggers StaticFetcher
  ```
- **Baseline connectivity:** 15/15 OK, ~1.9ms query latency against Dedicated

### What doesn't work

| Issue | Root Cause |
|-------|------------|
| Metrics reader panics (nil etcd) | `BackendReader.queryAllOwners()` calls `etcdCli.Get()` on nil — panic recovered but logs errors every 5s |
| Connection migration after backend change | `ScoreBasedRouter` needs metrics reader for rebalancing scores — broken without PD |
| Backend TLS to Essential | `[security.sql-tls] skip-ca = true` alone doesn't enable client TLS — TiProxy logs "no CA, disable TLS". Essential rejects with "insecure transport not allowed" |
| Namespace commit is undocumented | `PUT` alone only saves config; `POST /commit` is required to rebuild the namespace and activate `StaticFetcher` |

### Versions tested

v1.3.0, v1.3.2, v1.4.0-beta.1-nightly — all exhibit the same behavior.

### Verdict

TiProxy is designed for **within-cluster use** (deployed alongside TiDB/PD). As an external proxy to TiDB Cloud, it can establish baseline connections to Dedicated (non-TLS-required) backends but cannot migrate connections or connect to Essential (TLS-required) backends. Use HAProxy or ProxySQL instead.

## Key Findings

1. **ProxySQL wins for zero-downtime failover.** L7 runtime reconfiguration swaps backends without dropping client connections. HAProxy requires restart at L4.
2. **HAProxy is simpler and lower overhead** but accepts a brief connection reset during failover (~2s window).
3. **Same-region EC2 eliminates network noise.** Query latency from EC2 (~1.5ms) vs from macOS (~35ms) shows the value of co-located proxy.
4. **MySQL STARTTLS works through both proxies.** HAProxy passes it through (L4). ProxySQL terminates and re-initiates (`use_ssl=1`).
5. **VERSION() reliably discriminates tiers.** Dedicated returns `8.0.11-TiDB-v8.5.3`, Essential returns `8.0.11-TiDB-v8.5.3-serverless`.

## File Structure

```text
draft-lab-11-cloud-proxy-failover/
├── README.md
├── .env.example
├── .gitignore
├── probe.py                         # Failover probe (pymysql, detects backend via VERSION())
├── conf/
│   ├── haproxy/
│   │   └── haproxy.cfg              # L4 TCP proxy template
│   └── proxysql/
│       ├── proxysql.cnf.tmpl        # L7 MySQL proxy template (placeholders)
│       └── proxysql.cnf             # Generated at runtime (gitignored)
├── scripts/
│   ├── common.sh                    # Env, switchover functions, probe runner
│   ├── step0-smoke-test.sh          # Verify auth + connectivity
│   ├── step1-start.sh               # Start proxies → Dedicated
│   ├── step2-haproxy-test.sh        # HAProxy baseline + failover
│   ├── step3-proxysql-test.sh       # ProxySQL baseline + failover
│   ├── stepN-cleanup.sh             # Stop proxies
│   └── run-all.sh                   # Orchestrator
└── results/                         # Probe logs + summaries (gitignored)
```

## EC2 Setup

```bash
# Install dependencies (Amazon Linux 2023, ARM64)
sudo dnf install -y haproxy mariadb105 python3-pip
pip3 install pymysql==1.1.1
sudo dnf install -y https://github.com/sysown/proxysql/releases/download/v2.7.1/proxysql-2.7.1-1-almalinux9.aarch64.rpm

# Run
./scripts/run-all.sh
```

## Cleanup

```bash
# Stop proxies
./scripts/stepN-cleanup.sh

# Terminate EC2 instance
aws ec2 terminate-instances --instance-ids <id> --region us-east-1

# Remove EC2 IP from Dedicated cluster's IP access list
# TiDB Cloud Console → Networking → Edit IP Address
```

## References

- [HAProxy documentation](https://docs.haproxy.org/)
- [ProxySQL documentation](https://proxysql.com/documentation/)
- [TiProxy documentation](https://docs.pingcap.com/tidb/stable/tiproxy-overview)
- [TiDB Cloud TLS for Dedicated](https://docs.pingcap.com/tidbcloud/tidb-cloud-tls-connect-to-dedicated/)
- [TiDB Cloud TLS for Essential](https://docs.pingcap.com/tidbcloud/secure-connections-to-serverless-clusters/)
