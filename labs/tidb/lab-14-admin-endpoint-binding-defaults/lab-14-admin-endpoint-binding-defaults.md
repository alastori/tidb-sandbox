<!-- lab-meta
archetype: investigation
status: released
products: [tidb, tikv, pd]
-->

# Lab-14 - TiDB / TiKV / PD admin-endpoint binding defaults

**Goal:** Investigate how TiDB, TiKV, and PD bind their administrative HTTP listeners by default, what flags exist to change those defaults, and which endpoints are reachable from outside the host without authentication.

## Tested Environment

- TiDB v8.5.6 (`pingcap/tidb:v8.5.6`, `8.0.11-TiDB-v8.5.6`, git_hash `ae18096e023780bb56bfce33698abec0d4640d0a`)
- TiKV v8.5.6 (`pingcap/tikv:v8.5.6`)
- PD v8.5.6 (`pingcap/pd:v8.5.6`)
- TiUP v1.16.x with `tiup playground v8.5.6` (used by phases 1, 2, 3)
- Docker Engine 28.5.x (Colima backend on macOS) with `docker compose` v2 (used by phase 4)
- Probe container: `nicolaka/netshoot:v0.13` (used by phase 4)
- macOS 15.x on arm64
- Default ports: TiDB SQL 4000, TiDB status 10080, TiKV cluster 20160, TiKV status 20180, PD client 2379, PD peer 2380

## Hypotheses

1. **H1 - Listener separation.** TiDB and TiKV ship a separate flag for the admin / status listener, distinct from the cluster-traffic flag. PD inherits etcd's two-listener model (`--client-urls`, `--peer-urls`), which carries both client API and admin / debug routes on `--client-urls`.
2. **H2 - Default exposure (single-host dev).** Out of the box in `tiup playground`, the TiDB status listener binds to `0.0.0.0` and is reachable from any host on the network. The TiDB SQL listener, the TiKV status listener, and the PD client listener bind to `127.0.0.1` (single-host dev convenience).
3. **H3 - Network reachability of admin routes (single-host dev).** A reachable LAN probe of the TiDB status port returns 200 with no authentication for `/info`, `/debug/pprof/`, and `/config`, leaking version, git hash, DDL owner ID, server ID, and the full server config.
4. **H4 - Production-style exposure is wider than playground.** When TiDB / TiKV / PD are deployed each in its own container (a faithful proxy for the multi-host topology that `tiup cluster` deploys with `listen_host: 0.0.0.0` per the upstream topology reference), every component's admin / status / client listener binds to `0.0.0.0` and is reachable from any other node on the cluster network without authentication. The single-host `tiup playground` localhost-binding of TiKV status and PD client does not carry over to production.

## Phase 1 - Flag inventory

```bash
./phase1-flag-inventory.sh
```

This phase reads `--help` for `tidb-server`, `tikv-server`, and `pd-server` and grep's for the listener-related flags. No cluster is required. Confirm that:

- `tidb-server --status-host` exists and defaults to `0.0.0.0`.
- `tikv-server --status-addr` exists, separate from `-A/--addr`.
- `pd-server` has `--client-urls` and `--peer-urls`, and PD's HTTP admin / debug routes share `--client-urls`.

The TiDB upstream config at [`pkg/config/config.toml.example`](https://github.com/pingcap/tidb/blob/master/pkg/config/config.toml.example) documents `status-host = "0.0.0.0"` in the `[status]` section.

## Phase 2 - Bind audit

```bash
./phase2-bind-audit.sh
```

This phase starts a single-host `tiup playground v8.5.6` and uses `lsof` to audit which interface each listener binds to. The audit confirms which ports `tiup playground` binds to localhost and which it leaves open on all interfaces.

Leave the playground running for Phase 3.

## Phase 3 - Network reach probe

```bash
HOST_IP=$(ipconfig getifaddr en0)  # macOS; use a non-loopback host IP on Linux
./phase3-network-reach.sh "$HOST_IP"
```

This phase probes the TiDB status port, the TiKV status port, and the PD client port from the host's non-loopback IP. The phase does not require a remote machine; binding behavior is the same whether the probe originates from the same host's LAN IP or a different machine on the same subnet.

Tear down with `./cleanup.sh` when done with phases 2 and 3.

## Phase 4 - Production-style multi-container bind audit

```bash
./phase4-multi-host-bind-audit.sh
```

This phase brings up TiDB / TiKV / PD each in its own container via [`docker-compose.yml`](docker-compose.yml), and probes each component's listeners from a separate `lab14-probe` container on the same bridge network. The multi-container topology emulates a production multi-host deployment: each component runs in its own network namespace and reaches the others via container hostnames (`pd-0`, `tikv-0`, `tidb-0`), the same way binaries on separate hosts would reach each other on a routable network.

This is not a `tiup cluster deploy` install (which requires SSH between hosts and is heavy to set up); it is a faithful proxy for the binary's bind-and-reach behavior in a multi-host topology. The compose file pins `pingcap/pd:v8.5.6`, `pingcap/tikv:v8.5.6`, `pingcap/tidb:v8.5.6`, and `nicolaka/netshoot:v0.13` (probe container).

> **Note:** First run pulls roughly 700 MB of images (`pingcap/{pd,tikv,tidb}:v8.5.6` plus the netshoot probe image). Subsequent runs use the local image cache.

After Phase 4, run `./cleanup.sh` to tear down both the docker-compose topology and any leftover playground from phases 2 and 3.

## Findings Summary

| Phase | Hypothesis | Result | Key observation |
|-------|------------|--------|-----------------|
| 1 | H1 (listener separation) | Confirmed | `tidb-server --status-host` (default `0.0.0.0`), `tikv-server --status-addr`, and `pd-server --client-urls` / `--peer-urls` are all separate flags. PD's admin / debug routes ride on `--client-urls`. |
| 2 | H2 (default exposure, dev) | Confirmed | TiDB status :10080 binds to `*` (all interfaces). TiDB SQL :4000, TiKV status :20180, and PD client :2379 all bind to `127.0.0.1` under `tiup playground`. |
| 3 | H3 (network reach, dev) | Confirmed | `GET http://<lan-ip>:10080/info`, `/debug/pprof/`, `/config` return 200 with no auth from any reachable network address. TiKV status and PD client refuse the same probes (connection refused). |
| 4 | H4 (production-style exposure) | Confirmed | In a multi-container deploy (faithful proxy for `tiup cluster`), every listener binds to a routable address. Cross-container probes return 200 for `tidb-0:10080/info`, `tidb-0:10080/debug/pprof/`, `tidb-0:10080/config`, `tikv-0:20180/config`, `pd-0:2379/pd/api/v1/config`, `pd-0:2379/debug/pprof/`. The dev-mode localhost binding of TiKV status and PD client does not carry over. |

### Sample disclosure from `/info`

```text
{
  "is_owner": true,
  "max_procs": 28,
  "gogc": 500,
  "version": "8.0.11-TiDB-v8.5.6",
  "git_hash": "ae18096e023780bb56bfce33698abec0d4640d0a",
  "ddl_id": "8a2142b0-66bc-4504-81fa-a52f7b1c586f",
  "ip": "127.0.0.1",
  "listening_port": 4000,
  "status_port": 10080,
  "lease": "45s",
  "start_timestamp": 1778732055,
  "server_id": 1759,
  "labels": {}
}
```

## Conclusion

The architectural prerequisite for binding the TiDB / TiKV admin listener to localhost by default is already in place: each component ships a separate listener flag, distinct from the cluster-traffic listener. The change to default the admin listener to localhost is a flag-default flip plus a downstream-tooling rollout, not a new listener architecture.

PD is a separate case. PD inherits etcd's two-listener model and its admin / debug routes share `--client-urls` with the etcd-style cluster client API. To localhost-bind PD's admin without breaking cluster operation, PD would need either a new admin listener (etcd divergence) or per-route filtering on the existing one.

The single-host `tiup playground` audit is not representative of production. Phase 4 exercises a multi-container topology that emulates a production multi-host deployment and shows that the binaries' built-in defaults bind to a routable address in each container's network namespace, so every listener (TiDB status, TiKV status, PD client) is reachable from any other node on the cluster network without authentication. The [`tiup cluster` topology reference](https://docs.pingcap.com/tidb/stable/tiup-cluster-topology-reference/) documents the same observable outcome via a different mechanism: `tiup cluster` writes a config-template default of `listen_host: 0.0.0.0` for each node, which results in the same per-host bind behavior that Phase 4 demonstrates per-container. The lab tests the binary defaults; the docs describe the config-template defaults; both converge on the same exposure shape. TiDB Operator deployments on Kubernetes are expected (per the standard Kubernetes networking model, not tested in this lab) to bind pods to `0.0.0.0` and rely on Services and NetworkPolicy for cross-pod reach. Any default-flip work would need to be coordinated across `tiup playground`, `tiup cluster`, and the TiDB Operator chart.

## What this lab does not test

- Real `tiup cluster deploy` over SSH. Phase 4 emulates the multi-host topology with a docker-compose bridge network; a real `tiup cluster` install adds SSH plumbing and per-host TLS / firewall configuration that this lab does not exercise.
- TLS-enabled flow. The probes are plain HTTP. TLS is set up via [Enable TLS Between Components](https://docs.pingcap.com/tidb/stable/enable-tls-between-components/) and changes the auth posture, not the bind behavior.
- TiDB Operator / Kubernetes deployment. K8s pod-internal binding behavior is referenced in the conclusion but not exercised here. A follow-on phase using `kind` + the tidb-operator helm chart would close that gap.

## References

- [TiDB - status section in `config.toml.example`](https://github.com/pingcap/tidb/blob/master/pkg/config/config.toml.example) - documents `status-host = "0.0.0.0"` default
- [TiUP cluster topology reference](https://docs.pingcap.com/tidb/stable/tiup-cluster-topology-reference/) - `listen_host` global default
- [Enable TLS Between Components](https://docs.pingcap.com/tidb/stable/enable-tls-between-components/) - production TLS posture and `verify-component-callers-identity`
- [etcd configuration docs](https://etcd.io/docs/latest/op-guide/configuration/) - `--listen-client-urls` and `--listen-peer-urls` separation
