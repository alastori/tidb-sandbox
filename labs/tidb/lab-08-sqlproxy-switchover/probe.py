#!/usr/bin/env python3
"""SQL proxy switchover probe — measures proxy behavior during backend failover.

Tests multiple SQL proxies simultaneously by running concurrent probe loops.
Each proxy endpoint is probed in its own thread, measuring connection stability,
backend routing, and latency during a TiDB backend switchover event.

Requires: pymysql

Usage:
    python3 probe.py \
        --target tiproxy --host 127.0.0.1 --port 6000 \
        --target proxysql --host 127.0.0.1 --port 6002 \
        --target haproxy --host 127.0.0.1 --port 6001 \
        --duration 30 --interval 0.5
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import pymysql


@dataclass
class ProbeResult:
    timestamp: float
    success: bool
    latency_ms: float = 0.0
    connection_id: int | None = None
    tidb_version: str = ""
    resolved_ip: str = ""
    server_addr: str = ""  # @@hostname — which TiDB container answered
    error: str = ""


@dataclass
class ProbeStats:
    target: str
    endpoint: str
    results: list[ProbeResult] = field(default_factory=list)

    @property
    def total(self) -> int:
        return len(self.results)

    @property
    def successes(self) -> int:
        return sum(1 for r in self.results if r.success)

    @property
    def failures(self) -> int:
        return self.total - self.successes

    @property
    def success_rate(self) -> float:
        return (self.successes / self.total * 100) if self.total else 0.0

    @property
    def avg_latency_ms(self) -> float:
        lats = [r.latency_ms for r in self.results if r.success]
        return sum(lats) / len(lats) if lats else 0.0

    @property
    def p99_latency_ms(self) -> float:
        lats = sorted(r.latency_ms for r in self.results if r.success)
        if not lats:
            return 0.0
        idx = int(len(lats) * 0.99)
        return lats[min(idx, len(lats) - 1)]

    @property
    def max_latency_ms(self) -> float:
        lats = [r.latency_ms for r in self.results if r.success]
        return max(lats) if lats else 0.0

    @property
    def max_gap_seconds(self) -> float:
        success_times = [r.timestamp for r in self.results if r.success]
        if len(success_times) < 2:
            return 0.0
        return max(
            success_times[i + 1] - success_times[i]
            for i in range(len(success_times) - 1)
        )

    @property
    def conn_id_changes(self) -> int:
        ids = [r.connection_id for r in self.results if r.connection_id is not None]
        return sum(1 for i in range(1, len(ids)) if ids[i] != ids[i - 1])

    @property
    def backend_changes(self) -> int:
        addrs = [r.server_addr for r in self.results if r.server_addr]
        return sum(1 for i in range(1, len(addrs)) if addrs[i] != addrs[i - 1])

    @property
    def unique_backends(self) -> list[str]:
        return sorted({r.server_addr for r in self.results if r.server_addr})

    @property
    def endpoint_stable(self) -> bool:
        ips = {r.resolved_ip for r in self.results if r.resolved_ip}
        return len(ips) <= 1

    @property
    def failure_windows(self) -> list[dict]:
        windows = []
        in_failure = False
        start = 0.0
        for r in self.results:
            if not r.success and not in_failure:
                in_failure = True
                start = r.timestamp
            elif r.success and in_failure:
                in_failure = False
                windows.append({
                    "start": start,
                    "end": r.timestamp,
                    "duration_s": round(r.timestamp - start, 2),
                })
        if in_failure and self.results:
            windows.append({
                "start": start,
                "end": self.results[-1].timestamp,
                "duration_s": round(self.results[-1].timestamp - start, 2),
            })
        return windows


# Thread-safe print lock
_print_lock = threading.Lock()


def probe_loop(
    target_name: str,
    host: str,
    port: int,
    user: str,
    password: str,
    database: str,
    duration: float,
    interval: float,
    stats: ProbeStats,
):
    """Run probes for the given duration (runs in its own thread)."""
    conn = None
    end_time = time.monotonic() + duration
    probe_num = 0

    while time.monotonic() < end_time:
        probe_num += 1
        t0 = time.monotonic()

        try:
            if conn is None:
                conn = pymysql.connect(
                    host=host,
                    port=port,
                    user=user,
                    password=password,
                    database=database,
                    connect_timeout=5,
                    read_timeout=5,
                )

            with conn.cursor() as cur:
                cur.execute("SELECT CONNECTION_ID(), @@version, @@hostname")
                row = cur.fetchone()

            latency_ms = (time.monotonic() - t0) * 1000
            result = ProbeResult(
                timestamp=time.time(),
                success=True,
                latency_ms=latency_ms,
                connection_id=row[0],
                tidb_version=row[1] if row[1] else "",
                resolved_ip=host,
                server_addr=row[2] if row[2] else "",
            )

        except Exception as e:
            latency_ms = (time.monotonic() - t0) * 1000
            result = ProbeResult(
                timestamp=time.time(),
                success=False,
                latency_ms=latency_ms,
                resolved_ip=host,
                error=str(e)[:120],
            )
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass
                conn = None

        stats.results.append(result)

        # Live output
        ts = datetime.fromtimestamp(result.timestamp, tz=timezone.utc).strftime(
            "%H:%M:%S.%f"
        )[:12]

        if result.success:
            detail = (
                f"conn={result.connection_id}  "
                f"backend={result.server_addr}  "
                f"{result.latency_ms:.0f}ms"
            )
            marker = "OK"
        else:
            detail = result.error[:60]
            marker = "FAIL"

        # Detect events
        events = []
        if len(stats.results) >= 2:
            prev = stats.results[-2]
            if (
                result.success and prev.success
                and result.connection_id != prev.connection_id
                and prev.connection_id is not None
            ):
                events.append(
                    f"CONN_CHANGE {prev.connection_id}->{result.connection_id}"
                )
            if (
                result.success and prev.success
                and result.server_addr != prev.server_addr
                and prev.server_addr
            ):
                events.append(
                    f"BACKEND_SWITCH {prev.server_addr}->{result.server_addr}"
                )

        event_str = f"  *** {', '.join(events)}" if events else ""

        with _print_lock:
            print(
                f"  [{ts}] {target_name:<10} #{probe_num:>3}  {marker:<4} "
                f"{detail}{event_str}"
            )

        elapsed = time.monotonic() - t0
        sleep_time = max(0, interval - elapsed)
        time.sleep(sleep_time)

    if conn:
        try:
            conn.close()
        except Exception:
            pass


def print_report(stats_list: list[ProbeStats]) -> None:
    print(f"\n{'=' * 70}")
    print("  SWITCHOVER SMOKE TEST REPORT")
    print(f"{'=' * 70}")

    for stats in stats_list:
        print(f"\n  [{stats.target}] {stats.endpoint}")
        print(f"  {'─' * 60}")
        print(
            f"  Probes:        {stats.total} total, "
            f"{stats.successes} ok, {stats.failures} failed"
        )
        print(f"  Success rate:  {stats.success_rate:.1f}%")
        print(
            f"  Latency:       avg {stats.avg_latency_ms:.1f}ms  "
            f"p99 {stats.p99_latency_ms:.1f}ms  "
            f"max {stats.max_latency_ms:.1f}ms"
        )
        print(f"  Max gap:       {stats.max_gap_seconds:.2f}s")
        print(
            f"  Conn IDs:      "
            f"{len({r.connection_id for r in stats.results if r.connection_id})} "
            f"unique ({stats.conn_id_changes} changes)"
        )
        backends_set = set(stats.unique_backends)
        print(
            f"  Backends:      {backends_set} ({stats.backend_changes} switches)"
        )
        print(
            f"  Endpoint DNS:  "
            f"{'STABLE' if stats.endpoint_stable else 'CHANGED'} "
            f"({{{', '.join(repr(ip) for ip in sorted({r.resolved_ip for r in stats.results if r.resolved_ip}))}}})"
        )

        # Backend switchover timeline
        if stats.backend_changes > 0:
            print(f"  Backend switchover timeline:")
            addrs = [
                (r.timestamp, r.server_addr)
                for r in stats.results
                if r.server_addr
            ]
            for i in range(1, len(addrs)):
                if addrs[i][1] != addrs[i - 1][1]:
                    t = datetime.fromtimestamp(
                        addrs[i][0], tz=timezone.utc
                    ).strftime("%H:%M:%S")
                    print(f"    {t}: {addrs[i - 1][1]} -> {addrs[i][1]}")

        windows = stats.failure_windows
        if windows:
            print(f"  Failure windows:")
            for w in windows:
                t = datetime.fromtimestamp(
                    w["start"], tz=timezone.utc
                ).strftime("%H:%M:%S")
                print(f"    {t} — {w['duration_s']}s")

    # Comparison table
    if len(stats_list) > 1:
        names = [s.target for s in stats_list]
        col_w = max(14, max(len(n) for n in names) + 2)
        header = "Metric".ljust(35) + "".join(n.rjust(col_w) for n in names)
        sep = "─" * (35 + col_w * len(names))
        print(f"\n  {sep}")
        print(f"  COMPARISON: {' vs '.join(names)}")
        print(f"  {sep}")
        print(f"  {header}")
        print(f"  {sep}")

        rows = [
            ("Success rate", [f"{s.success_rate:.1f}%" for s in stats_list]),
            ("Avg latency", [f"{s.avg_latency_ms:.1f}ms" for s in stats_list]),
            ("P99 latency", [f"{s.p99_latency_ms:.1f}ms" for s in stats_list]),
            ("Max gap", [f"{s.max_gap_seconds:.2f}s" for s in stats_list]),
            ("Conn ID changes", [str(s.conn_id_changes) for s in stats_list]),
            ("Backend switches", [str(s.backend_changes) for s in stats_list]),
            ("Failure windows", [str(len(s.failure_windows)) for s in stats_list]),
            (
                "Total failure time",
                [
                    f"{sum(w['duration_s'] for w in s.failure_windows):.2f}s"
                    for s in stats_list
                ],
            ),
        ]
        for label, vals in rows:
            print(f"  {label:<35}{''.join(v.rjust(col_w) for v in vals)}")

    # Verdict
    all_stable = all(s.endpoint_stable for s in stats_list)
    print(f"\n{'=' * 70}")
    if all_stable:
        print(f"  VERDICT: PASS — proxy endpoint(s) stable, no DNS changes")
    else:
        print(f"  VERDICT: WARN — endpoint instability detected")
    print(f"{'=' * 70}\n")


def save_results(stats_list: list[ProbeStats], output_path: str):
    data = {}
    for stats in stats_list:
        data[stats.target] = {
            "endpoint": stats.endpoint,
            "total": stats.total,
            "successes": stats.successes,
            "failures": stats.failures,
            "success_rate": round(stats.success_rate, 2),
            "avg_latency_ms": round(stats.avg_latency_ms, 2),
            "p99_latency_ms": round(stats.p99_latency_ms, 2),
            "max_latency_ms": round(stats.max_latency_ms, 2),
            "max_gap_s": round(stats.max_gap_seconds, 3),
            "conn_id_changes": stats.conn_id_changes,
            "backend_changes": stats.backend_changes,
            "unique_backends": stats.unique_backends,
            "failure_windows": stats.failure_windows,
            "endpoint_stable": stats.endpoint_stable,
            "probes": [asdict(r) for r in stats.results],
        }

    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"  Results saved to {output_path}")


def main():
    parser = argparse.ArgumentParser(description="SQL Proxy Switchover Probe")
    parser.add_argument("--target", action="append", help="Target name (repeatable)")
    parser.add_argument("--host", action="append", help="Hostname (repeatable)")
    parser.add_argument("--port", action="append", type=int, help="Port (repeatable)")
    parser.add_argument("--user", default="root")
    parser.add_argument("--password", default="")
    parser.add_argument("--database", default="test")
    parser.add_argument("--duration", type=float, default=30)
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--output", default="")

    args = parser.parse_args()

    names = args.target or []
    hosts = args.host or []
    ports = args.port or []

    if not names:
        parser.error("At least one --target required")
    if len(names) != len(hosts) or len(names) != len(ports):
        parser.error("Each --target needs matching --host and --port")

    targets_str = ", ".join(
        f"{n} ({h}:{p})" for n, h, p in zip(names, hosts, ports)
    )
    print(f"\n{'=' * 70}")
    print(f"  SQL Proxy Switchover Probe")
    print(f"  Targets: {targets_str}")
    print(f"  Duration: {args.duration}s  Interval: {args.interval}s")
    print(f"{'=' * 70}")

    stats_list = []
    threads = []

    for name, host, port in zip(names, hosts, ports):
        stats = ProbeStats(target=name, endpoint=f"{host}:{port}")
        stats_list.append(stats)

        t = threading.Thread(
            target=probe_loop,
            kwargs={
                "target_name": name,
                "host": host,
                "port": port,
                "user": args.user,
                "password": args.password,
                "database": args.database,
                "duration": args.duration,
                "interval": args.interval,
                "stats": stats,
            },
            daemon=True,
        )
        threads.append(t)

    # Start all probe threads simultaneously
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    print_report(stats_list)

    if args.output:
        save_results(stats_list, args.output)

    sys.exit(0)


if __name__ == "__main__":
    main()
