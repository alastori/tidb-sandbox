<!-- lab-meta
archetype: investigation
status: released
products: [tidb, tikv, pd, tiflash]
-->

# Lab-15 - TiDB cluster startup behavior with and without inter-component TLS

**Goal:** Characterize what an operator observes at startup when TiDB / TiKV / PD are brought up **without** TLS for inter-component traffic (today's default) vs **with** TLS configured (recommended posture). The lab is structured as A/B comparison across four operator-facing deployment contexts. Phases 1, 3, and 4 have both a "TLS off" and a "TLS on" variant; phase 2 (`tiup playground`) is TLS-off only because playground exposes no TLS flag (see H2). TiFlash is started only in phase 2's TLS-off baseline; phase 1 has a TiFlash placeholder row, and phases 3 and 4 omit TiFlash to keep the topology lean.

## Quick Start

Every phase greps each component's startup log against `LOG_SUBSTR='(tls|ssl)'` and prints **every matching line** under a one-line `[label] N matches:` header. The scripts dump raw evidence; analysis and consolidation across phases lives in the [Findings Summary](#findings-summary) below. Compare the TLS-off vs TLS-on output to see what changes: the TLS-on run adds cert path strings (e.g., PD's `["starting with peer TLS"]` etcd init lines, populated `cluster-ssl-*` paths in the loaded-config dump). Some matches are baseline noise that always appears (config-dump SSL keys, TiKV's `openssl-vendored`, TiDB's SQL-side TLS warning) and the lab calls those out so the operator can ignore them.

**Tunable env var** (applies to every phase):

- `LOG_SUBSTR` (default `(tls|ssl)`, case-insensitive ERE): the pattern each phase greps for. Set to a future warning text like `enable-cluster-tls-warning` to verify a specific message lands in the startup logs.

### Bare process (phase 1)

A/B/C comparison across `tidb-server`, `tikv-server`, `pd-server` (TiFlash bare-process is a placeholder row). Requires cert generation first.

```bash
./setup-certs.sh
./phase1-bare-process.sh
```

<details>
<summary>Expected output (click to expand; verified on TiDB v8.5.6, abbreviated with <code>...</code> where the config-dump JSON is multi-KB)</summary>

```text
--- tidb-server ---
  [tidb-server-A-default] 2 matches:
    ["loaded config"] [config="...security:{cluster-ssl-ca:"",cluster-ssl-cert:"",cluster-ssl-key:""...
    [WARN] ["Automatic TLS Certificate creation is disabled"]
  [tidb-server-B-tls-configured] 2 matches:
    ["loaded config"] [config="...security:{cluster-ssl-ca:"<lab>/certs/ca.pem",cluster-ssl-cert:"...
    [WARN] ["Automatic TLS Certificate creation is disabled"]
  [tidb-server-C-silenced] 3 matches:
    <config rejected; the silence flag is unknown to current TiDB>

--- tikv-server ---
  [tikv-server-A-default] 2 matches:
    ["Enable Features: ... openssl-vendored"]
    ["OpenSSL FIPS mode is disabled"]
  [tikv-server-B-tls-configured] 2 matches:
    <same two baseline lines; tikv is stuck reconnecting to PD before the security init logs land>
  [tikv-server-C-silenced] 2 matches:
    <same two baseline lines>

--- pd-server ---
  [pd-server-A-default] 1 matches:
    ["PD config"] [config="...client-urls":"http://...security:{cacert-path:"",cert-path:"",key-path:""...
  [pd-server-B-tls-configured] 3 matches:
    ["PD config"] [config="...client-urls":"https://...cacert-path":"<lab>/certs/ca.pem",cert-path":"...
    ["starting with peer TLS"]   [tls-info="cert = <lab>/certs/server.pem, key = ..., trusted-ca = <lab>/certs/ca.pem, client-cert-auth = true, crl-file = "]
    ["starting with client TLS"] [tls-info="cert = <lab>/certs/server.pem, key = ..., trusted-ca = <lab>/certs/ca.pem, client-cert-auth = true, crl-file = "]
  [pd-server-C-silenced] 2 matches:
    [WARN] ["Config contains undefined item: security.enable-cluster-tls-warning"]
    ["PD config"] [config="..."]

--- tiflash ---
  [tiflash-A-default]            no matches   (placeholder row; prints a note instead of starting)
  [tiflash-B-tls-configured]     no matches
  [tiflash-C-silenced]           no matches
```

</details>

Bare-process probing in 5 seconds cannot drive a real TLS handshake (TiKV and TiDB need PD up first, and PD needs etcd peers). The TLS-on signal at this layer is in PD's two extra etcd init lines and in TiDB's loaded-config dump going from empty to populated `cluster-ssl-*` paths. For full TLS handshake evidence, see phase 3 or phase 4.

### TiUP playground (phase 2)

TLS-off baseline only. `tiup playground` does not expose a TLS flag (verified up to v1.16.5), so this phase confirms the per-component baseline counts in a playground deployment context but cannot show the TLS-on side of the delta. For TLS-on, see phases 1, 3, or 4.

```bash
./phase2-tiup-playground.sh
```

<details>
<summary>Expected output (click to expand; verified on TiDB v8.5.6, counts are higher than other phases because playground stays running long enough to log many tiflash bring-up lines that incidentally match <code>(tls|ssl)</code>)</summary>

```text
Run 2A: TLS off (default; only mode tiup playground supports)
  [tidb] 4 matches:
    [<file>] ["loaded config"] [config="...security:{cluster-ssl-ca:""...
    [<file>] [WARN] ["Automatic TLS Certificate creation is disabled"]
    [<file>] (additional matches inside the config dump JSON)
  [tikv] 10 matches:
    [<file>] ["Enable Features: ... openssl-vendored"]
    [<file>] ["OpenSSL FIPS mode is disabled"]
    [<file>] ... (config dump + status init lines mentioning TLS keys)
  [pd] 7 matches:
    [<file>] ["PD config"] [config="...client-urls":"http://...
    [<file>] ... (etcd init + dashboard config lines)
  [tiflash] 15 matches:
    [<file>] (tiflash bring-up logs reference TLS path strings even with TLS off)
```

</details>

### Multi-container production-style deploy (phase 3)

A/B comparison via `docker-compose`. Faithful proxy for `tiup cluster` with `listen_host: 0.0.0.0`. Requires Docker and cert generation.

```bash
./setup-certs.sh
./phase3-multi-container.sh
```

<details>
<summary>Expected output (click to expand; verified on TiDB v8.5.6, PD shows the cleanest delta as the etcd peer + client TLS init lines land in 3B; TiKV and TiDB stay flat at 2 because the populated cert paths in their config-dump JSON land on the same already-matched line, and the host-mounted <code>/certs/</code> path itself does not contain <code>tls</code>/<code>ssl</code> substrings)</summary>

```text
Run 3A: TLS off
  [lab15-pd-0] 1 matches:
    ["PD config"] [config="...client-urls":"http://...security:{cacert-path:"",cert-path:"",key-path:""...
  [lab15-tikv-0] 2 matches:
    ["Enable Features: ... openssl-vendored"]
    ["OpenSSL FIPS mode is disabled"]
  [lab15-tidb-0] 2 matches:
    ["loaded config"] [config="...security:{cluster-ssl-ca:"",cluster-ssl-cert:"",cluster-ssl-key:""...
    [WARN] ["Automatic TLS Certificate creation is disabled"]

Run 3B: TLS on
  [lab15-pd-0] 3 matches:
    ["PD config"] [config="...client-urls":"https://...security:{cacert-path:"/certs/ca.pem",cert-path:"/certs/server.pem"...
    ["starting with peer TLS"]   [tls-info="cert = /certs/server.pem, key = /certs/server-key.pem, trusted-ca = /certs/ca.pem..."]
    ["starting with client TLS"] [tls-info="cert = /certs/server.pem, key = /certs/server-key.pem, trusted-ca = /certs/ca.pem..."]
  [lab15-tikv-0] 2 matches:
    same two baseline lines as 3A (cert paths land in TiKV's config dump but on the same already-matched line)
  [lab15-tidb-0] 2 matches:
    same two lines as 3A (cluster-ssl-* paths populated but on the same line)
```

</details>

### TiDB Operator on Kubernetes (phase 4)

A/B comparison across two `TidbCluster` CRs (one with `spec.tlsCluster.enabled` unset, one with it set + cert-manager-issued Secrets). Requires `kind` + `helm` + `kubectl`; first run also installs `cert-manager` and the operator chart, ~5 min.

```bash
./phase4-operator-kind.sh
```

<details>
<summary>Expected output (click to expand; verified on TiDB v8.5.6 with operator v1.6.5; the <code>client-urls</code> scheme in the PD config-dump line is the cleanest discriminator: <code>http://</code> in 4A vs <code>https://</code> in 4B; TiKV gains a third match in 4B because the operator mounts certs at <code>/var/lib/tikv-tls/</code> and the path string itself contains <code>tls</code>)</summary>

```text
Run 4A: TLS off
  [lab15-pd-0] 1 matches:
    ["PD config"] [config="...client-urls":"http://...security:{cacert-path:"",cert-path:"",key-path:""...
  [lab15-tikv-0] 2 matches:
    ["Enable Features: ... openssl-vendored"]
    ["OpenSSL FIPS mode is disabled"]
  [lab15-tidb-0] 2 matches:
    ["loaded config"] [config="...security:{cluster-ssl-ca:"",cluster-ssl-cert:"",cluster-ssl-key:""...
    [WARN] ["Automatic TLS Certificate creation is disabled"]

Run 4B: TLS on
  [lab15-pd-0] 3 matches:
    ["PD config"] [config="...client-urls":"https://...security:{cacert-path":"/var/lib/pd-tls/ca.crt"...
    ["starting with peer TLS"]   [tls-info="cert = /var/lib/pd-tls/tls.crt..."]
    ["starting with client TLS"] [tls-info="cert = /var/lib/pd-tls/tls.crt..."]
  [lab15-tikv-0] 3 matches:
    ["Enable Features: ... openssl-vendored"]
    ["OpenSSL FIPS mode is disabled"]
    ["using config"] [config="...security:{ca-path":"/var/lib/tikv-tls/ca.crt",cert-path":"/var/lib/tikv-tls/tls.crt"...
  [lab15-tidb-0] 2 matches:
    ["loaded config"] [config="...security:{cluster-ssl-ca:"/var/lib/tidb-tls/ca.crt",cluster-ssl-cert:"/var/lib/tidb-tls/tls.crt"...
    [WARN] ["Automatic TLS Certificate creation is disabled"]
```

</details>

### Tear down

This also deletes the kind cluster, so re-running phase 4 starts from scratch (cluster + operator + cert-manager bootstrap, ~5 min).

```bash
./cleanup.sh
```

## Tested Environment

- TiDB v8.5.6 (`pingcap/tidb:v8.5.6`, `8.0.11-TiDB-v8.5.6`, git_hash `ae18096e023780bb56bfce33698abec0d4640d0a`)
- TiKV v8.5.6 (`pingcap/tikv:v8.5.6`)
- PD v8.5.6 (`pingcap/pd:v8.5.6`)
- TiFlash v8.5.6 (`pingcap/tiflash:v8.5.6`)
- TiUP v1.16.4 (component `playground`); used by phase 2 to pull TiDB v8.5.6 binaries
- Docker Engine 28.5.1 Community Edition with Colima backend on macOS, `docker compose` v2 (used by phase 3)
- `kind` v0.31.0, Helm v4.2.0, `kubectl` v1.36.1, `pingcap/tidb-operator` chart v1.6.5, `cert-manager` v1.16.2 (used by phase 4)
- macOS 26.4.1 (build 25E253) on arm64

## Hypotheses

1. **H1 - bare-process behavior is observably different between TLS off and TLS on.** Each of `tidb-server`, `tikv-server`, `pd-server` (TiFlash bare-process is a placeholder row in phase 1), when started without TLS, communicates in plaintext on the inter-component listeners. With cluster certificates configured, the same listeners require a TLS handshake (verifiable by curl-without-cert returning a TLS handshake error vs. plaintext HTTP, and by additional startup-log lines mentioning cert paths and TLS handshakes in the TLS-on case).
2. **H2 - `tiup playground` defaults to TLS off and provides no supported flag for TLS-on.** Verified empirically: `tiup playground --tls` returns `Error: unknown flag: --tls` in TiUP v1.16.4 and v1.16.5. Per-component `[security]` configs via `--db.config` / `--kv.config` / `--pd.config` can configure individual binaries with cert paths, but playground hard-codes `http://` in the inter-component URLs it wires up, so the cluster fails to form when any one component requires TLS. Net: phase 2 is a TLS-off baseline only; TLS-on coverage in dev environments comes from phase 1 (bare process) instead.
3. **H3 - production-style multi-container deploy defaults to TLS off** (faithful proxy for `tiup cluster` with `listen_host: 0.0.0.0` global default + no `[security]` section). Adding a cert volume + `[security]` section flips the cluster to TLS-required.
4. **H4 - TiDB Operator on Kubernetes defaults to TLS off; `spec.tlsCluster.enabled = true` flips to TLS on with operator-managed certs.** Verified empirically in phase 4 with `pingcap/tidb-operator` v1.6.5 on `kind`, using `cert-manager` to issue per-component cluster Secrets.

Forward-looking, in case a future TiDB release adds a startup-time warning about missing inter-component TLS:

5. **H5 (forward-looking).** TiDB / TiKV / PD / TiFlash today emit no purpose-built startup warning about missing inter-component TLS. All four binaries do log baseline lines that match the default `(tls|ssl)` substring even in TLS-off state (PD config dump SSL keys, TiKV's `openssl-vendored` feature line and `OpenSSL FIPS mode is disabled`, TiDB's SQL-side `Automatic TLS Certificate creation is disabled` warning), but none of those lines is a directed warning about cluster TLS being off. Should a future release add such a directed warning, the same lab scripts here serve as a ready-made verification harness: each phase accepts `LOG_SUBSTR` as an env var and can be retargeted at the new warning text without modification.

## Setup - Generate cluster certificates (one-time, before TLS-on phases)

```bash
./setup-certs.sh
```

Generates a self-signed CA plus a shared server cert with SANs covering both `localhost` / `127.0.0.1` (for phase 1 bare-process) and the multi-container hostnames `pd-0` / `tikv-0` / `tidb-0` / `tiflash-0` (for phase 3). Output goes to `./certs/` (gitignored). Idempotent: skips if certs already exist. Follows the cert-chain pattern in [TiDB - Generate Self-Signed Certificates](https://docs.pingcap.com/tidb/stable/generate-self-signed-certificates/) but uses one shared server cert across the components in phases 1 and 3 for simplicity (real production deployments use per-component certs with distinct CNs and `cluster-verify-cn` enforcement). Phase 4 does not consume these files; it issues per-component certs via cert-manager.

Required by phase 1 state B (TLS-on bare-process) and phase 3 pass 3B (TLS-on multi-container). Not used by phase 2 (which is TLS-off only because `tiup playground` has no TLS flag). Not used by phase 4, which issues per-component certs via cert-manager whose Secrets follow the operator's naming convention.

## Phase 1 - Bare process (TLS off vs TLS on)

```bash
./phase1-bare-process.sh
```

For each of `tidb-server`, `tikv-server`, `pd-server` (TiFlash bare-process is a placeholder row that prints a note instead of starting the binary, since TiFlash invocation needs the official build path), this phase exercises three configurations and captures the first `PROBE_SECONDS` (default 5) of the startup log:

| State | Config | What the operator observes |
|---|---|---|
| A | TLS off (today's default) | Startup log shows no cluster cert paths; inter-component listeners accept plaintext |
| B | TLS on (cluster certs from `./setup-certs.sh`) | PD's etcd init prints `["starting with peer TLS"]` and `["starting with client TLS"]` lines; PD's config dump shows populated `cacert-path`/`cert-path`/`key-path`. TiDB's loaded-config dump shows populated `cluster-ssl-*` paths. TiKV does not reach the security init logs in 5s (it loops trying to reach PD); for full handshake evidence see phase 3 or phase 4 |
| C | TLS off + `[security] enable-cluster-tls-warning = false` (forward-looking flag, no effect today) | Same as A today; PD logs a `Config contains undefined item: security.enable-cluster-tls-warning` WARN, TiDB rejects the config (strict parsing). The harness is ready to verify a future warning if one is added (per H5) |

States A and B are the mainline contrast. State C is forward-looking: it sets the silence flag against today's binaries (which ignore it) so the harness is ready to verify a future startup warning if one is added.

The lab greps each captured startup log against a configurable substring filter (`LOG_SUBSTR`, default `(tls|ssl)` case-insensitive ERE) and prints every matching line under a one-line `[label] N matches:` header. Some matches are baseline noise that always appears even in TLS-off state (PD config-dump SSL keys, TiKV's `openssl-vendored` feature line, TiDB's SQL-side TLS warning); the lab's [Findings Summary](#findings-summary) consolidates which lines are signal vs. noise per binary.

## Phase 2 - `tiup playground` (TLS-off baseline)

```bash
./phase2-tiup-playground.sh
```

Runs `tiup playground v8.5.6` once without TLS (the only mode `tiup playground` supports). Prints every line in each component's playground log files that matches `LOG_SUBSTR`. This phase is TLS-off baseline only because `tiup playground` provides no supported way to enable inter-component TLS (see H2). For the TLS-on contrast in a dev environment, see phase 1 (bare process); for production-style topologies, see phase 3 or phase 4.

## Phase 3 - Production-style multi-container deploy (TLS off vs TLS on)

```bash
./phase3-multi-container.sh
```

Two sequential passes against a multi-container topology (a faithful proxy for `tiup cluster` with `listen_host: 0.0.0.0` global default):

- **3A. TLS off** - uses `docker-compose.yml`. PD / TiKV / TiDB each in its own container, no certs, plaintext inter-component traffic.
- **3B. TLS on** - uses `docker-compose-tls.yml`. Mounts `./certs/` (from `./setup-certs.sh`) into each container plus a per-component `[security]` TOML overlay from `./tls-overlays/`. PD / TiKV / TiDB run with TLS-required listeners.

TiFlash is intentionally absent from both phase 3 passes. Its bring-up requires substantial extra config (`tiflash.toml` + `tiflash_proxy.toml` + RaftStore CA wiring) disproportionate to phase 3's demonstration value. TiFlash TLS-off is exercised by phase 2 (`tiup playground` brings up TiFlash automatically); TiFlash TLS-on is not directly exercised by this lab in any phase (`tiup playground` has no TLS flag, and we omitted TiFlash from phases 3 and 4 for topology lean).

The script prints every line in each container's `docker logs` output that matches `LOG_SUBSTR`. Pass 3B adds PD's etcd `["starting with peer TLS"]` and `["starting with client TLS"]` init lines; TiKV and TiDB's TLS-on cert paths land inside their existing config-dump lines so the count of matching lines stays the same but the line content changes (`http://` → `https://`, populated cert paths). Compare the two passes line-by-line to see what TLS engagement looks like at this layer.

## Phase 4 - TiDB Operator on Kubernetes

```bash
./phase4-operator-kind.sh
```

Two sequential passes against one `kind` cluster:

- **4A. TLS off** - applies `kind/tidb-cluster-no-tls.yaml` to namespace `lab15a`. `spec.tlsCluster.enabled` is unset (today's default).
- **4B. TLS on** - applies `kind/tidb-cluster-tls.yaml` to namespace `lab15b`. The manifest includes a `cert-manager` self-signed `Issuer` plus per-component `Certificate` resources whose `secretName` matches the convention the operator looks up when `spec.tlsCluster.enabled = true` (`<cluster>-{pd,tikv,tidb}-cluster-secret` and `<cluster>-cluster-client-secret`).

The script bootstraps the cluster + operator + cert-manager on first run (idempotent) and tears down only the per-pass namespaces between passes. It prints every line in each pod's `kubectl logs` output that matches `LOG_SUBSTR`. Pass 4B adds PD's etcd `["starting with peer TLS"]` / `["starting with client TLS"]` init lines and TiKV's `["using config"]` line (the latter matches because the operator mounts certs at `/var/lib/tikv-tls/`, which contains the `tls` substring). TiDB's `cluster-ssl-*` paths populate but land on the same config-dump line that already matched in 4A.

Heaviest of the four phases (requires `kind`, `helm`, `kubectl`; the script also installs `cert-manager` on first run). First run takes ~5 min for the kind cluster + operator + cert-manager bootstrap; subsequent runs reuse all of that and finish in ~2-3 min per pass.

## Findings Summary

Each phase script prints every matching line; this section consolidates the per-binary counts and the **specific lines that change between TLS-off and TLS-on**. The default `LOG_SUBSTR='(tls|ssl)'` pattern hits some baseline noise that always appears (PD config-dump SSL keys, TiKV's `openssl-vendored` and `OpenSSL FIPS` lines, TiDB's SQL-side `Automatic TLS Certificate creation is disabled` warning); the table below shows what to look at as signal vs. noise.

| Phase | Hypothesis | TLS off (counts) | TLS on (counts) |
|-------|------------|---------|--------|
| 1 | H1 (bare-process A/B/C across TiDB / TiKV / PD; TiFlash is a placeholder row) | low baseline counts: TiDB=2, TiKV=2, PD=1 | PD=3 (peer TLS + client TLS init lines added); TiDB=2 (cluster-ssl-* paths populated but on the same already-matched config line); TiKV=2 (process stuck reconnecting to PD before security init logs land; phase 3/4 cover the full handshake) |
| 2 | H2 (`tiup playground` no-TLS only; `--tls` is not a supported flag) | low baseline counts per component | N/A (TLS-on not supported by `tiup playground`; covered by phase 1 in the dev-environment context) |
| 3 | H3 (multi-container production-style PD / TiKV / TiDB, TLS off vs TLS on) | PD=1, TiKV=2, TiDB=2 | PD=3 (etcd peer + client TLS init lines added); TiKV=2 and TiDB=2 stay flat (host-mounted `/certs/` path does not contain `tls`/`ssl` substrings, and the populated cert paths land on the already-matched config-dump line) |
| 4 | H4 (Operator default vs `tlsCluster.enabled`) | PD=1 (config-dump SSL keys), TiKV=2 (`openssl-vendored`, `OpenSSL FIPS`), TiDB=2 (config-dump empty `cluster-ssl-*`, SQL-side warning) | PD=3 (4A line + etcd peer TLS + etcd client TLS), TiKV=3 (4A noise + populated cert paths in config dump), TiDB=2 (4A lines, populated `cluster-ssl-*` paths land on the same config-dump line) |
| 1-4 | H5 (forward-looking) | No directed startup warning about missing inter-component TLS in any phase. The baseline-noise lines that match `(tls|ssl)` are not warnings about cluster TLS being off | If a startup warning is ever added, retarget `LOG_SUBSTR` at its text and re-run any phase to verify |

## Conclusion

The lab establishes that today's TiDB / TiKV / PD binaries default to TLS-off across all four operator-facing deployment contexts. Switching to TLS-on is mechanical where the deployment surface supports it: cluster cert paths in the `[security]` section for the bare process (phase 1), cert-volume mounts plus per-component `[security]` overlays for the multi-container deploy (phase 3), and `spec.tlsCluster.enabled = true` plus operator-managed cert Secrets for TiDB Operator (phase 4). The `tiup playground` deployment surface (phase 2) provides no TLS flag and is TLS-off only.

The TLS engagement signal in the startup logs is most visible in PD: with cluster certs configured and `client-urls`/`peer-urls` switched to `https://`, PD's embedded etcd prints two distinct lines (`starting with peer TLS`, `starting with client TLS`) that do not appear in the TLS-off run. TiKV and TiDB carry their cert paths inside the same already-matched config-dump lines, so for those two the change is in line content (empty vs. populated `cluster-ssl-*` / `ca-path` strings), not in line count. For an operator evaluating their security posture, phase 3 (multi-container) is the most direct way to see a real cluster handshake; phase 4 (TiDB Operator) demonstrates the same with operator-managed certs. Reference docs for cert generation: [Generate Self-Signed Certificates](https://docs.pingcap.com/tidb/stable/generate-self-signed-certificates/).

## What this lab does not test

- Real `tiup cluster deploy` over SSH. Phase 3 emulates the multi-host topology via docker-compose; a real `tiup cluster` install adds SSH plumbing the lab does not exercise.
- TiFlash bare-process in phase 1 (placeholder row; needs the official TiFlash build path).
- TiFlash in phase 3 (full TiFlash bring-up is heavier; TiFlash TLS-off appears in phase 2's playground baseline only).
- TiFlash in phase 4 (the TidbCluster CRs in `kind/` omit `spec.tiflash` to keep the cluster small enough for kind on a laptop).
- TiFlash TLS-on in any phase. `tiup playground` has no TLS flag (phase 2), and we omitted TiFlash from phases 3 and 4. To exercise TiFlash TLS-on, follow [TiDB - Enable TLS Between Components](https://docs.pingcap.com/tidb/stable/enable-tls-between-components/) on a `tiup cluster` deploy.
- Per-component cert chains with `cluster-verify-cn` enforcement (phases 1 and 3 use one shared server cert across the components; phase 4 issues per-component certs but does not exercise CN allow-listing). Real production deployments use per-component certs with distinct CNs.
- Multi-replica TidbCluster in phase 4. The CRs use 1 PD / 1 TiKV / 1 TiDB to fit a kind cluster on a laptop; production deployments use 3+ replicas per role.

## References

- [TiDB - Enable TLS Between Components](https://docs.pingcap.com/tidb/stable/enable-tls-between-components/) - canonical setup docs
- [TiDB - Generate Self-Signed Certificates](https://docs.pingcap.com/tidb/stable/generate-self-signed-certificates/) - cert generation for the TLS-on phase states
- [TiUP cluster topology reference](https://docs.pingcap.com/tidb/stable/tiup-cluster-topology-reference/) - `listen_host: 0.0.0.0` global default that motivates the production-style multi-container proxy in phase 3
- [TiDB Operator - Enable TLS Between Components](https://docs.pingcap.com/tidb-in-kubernetes/stable/enable-tls-between-components/) - the secret naming convention and SAN list used by phase 4's `kind/tidb-cluster-tls.yaml`
- [cert-manager docs](https://cert-manager.io/docs/) - the CRDs (`Issuer`, `Certificate`) that produce the per-component Secrets in phase 4
