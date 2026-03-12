#!/usr/bin/env python3
"""Concurrent probe for TiProxy vs HAProxy switchover comparison.

Probes multiple TiDB proxy endpoints simultaneously and reports:
- Connection ID changes (proxy switchover signal)
- Query latency (avg, p99, max)
- Failure windows (gap duration, error types)
- Endpoint stability (DNS resolution changes)

Requires: pymysql  (pip install pymysql)

Usage:
    python3 probe.py \
        --target tiproxy --host 127.0.0.1 --port 6000 \
        --target haproxy --host 127.0.0.1 --port 6001 \
        --duration 30 --interval 0.5
"""

from __future__ import annotations

import argparse
import json
import socket
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
    server_addr: str = ""  # @@tidb_server_addr — which backend answered
    error: str = ""


@dataclass
class TargetConfig:
    name: str
    host: str
    port: int
    user: str = "root"
    password: str = ""
    database: str = "test"


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
        idx = max(0, int(len(lats) * 0.99) - 1)
        return lats[idx]

    @property
    def max_latency_ms(self) -> float:
        lats = [r.latency_ms for r in self.results if r.success]
        return max(lats) if lats else 0.0

    @property
    def unique_conn_ids(self) -> set[int]:
        return {r.connection_id for r in self.results if r.connection_id is not None}

    @property
    def unique_backends(self) -> set[str]:
        return {r.server_addr for r in self.results if r.server_addr}

    @property
    def unique_ips(self) -> set[str]:
        return {r.resolved_ip for r in self.results if r.resolved_ip}

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
    def endpoint_stable(self) -> bool:
        return len(self.unique_ips) <= 1

    @property
    def failure_windows(self) -> list[dict]:
        """Contiguous failure windows with start/end/duration."""
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


def resolve_host(host: str) -> str:
    try:
        return socket.gethostbyname(host)
    except socket.gaierror:
        return "unresolved"


def probe_loop(
    target: TargetConfig,
    duration: float,
    interval: float,
    stats: ProbeStats,
    lock: threading.Lock,
):
    """Run probes in a loop for the given duration. Thread-safe."""
    conn = None
    end_time = time.monotonic() + duration
    probe_num = 0

    while time.monotonic() < end_time:
        probe_num += 1
        t0 = time.monotonic()
        resolved_ip = resolve_host(target.host)

        try:
            # Reconnect if needed
            if conn is None:
                conn = pymysql.connect(
                    host=target.host,
                    port=target.port,
                    user=target.user,
                    password=target.password,
                    database=target.database,
                    connect_timeout=5,
                    read_timeout=5,
                )
            else:
                try:
                    conn.ping(reconnect=False)
                except Exception:
                    conn = pymysql.connect(
                        host=target.host,
                        port=target.port,
                        user=target.user,
                        password=target.password,
                        database=target.database,
                        connect_timeout=5,
                        read_timeout=5,
                    )

            with conn.cursor() as cur:
                # Get connection ID + which backend answered
                cur.execute(
                    "SELECT CONNECTION_ID(), @@version, @@hostname"
                )
                row = cur.fetchone()

            latency_ms = (time.monotonic() - t0) * 1000
            result = ProbeResult(
                timestamp=time.time(),
                success=True,
                latency_ms=latency_ms,
                connection_id=row[0],
                tidb_version=row[1],
                resolved_ip=resolved_ip,
                server_addr=row[2] if row[2] else "",
            )

        except Exception as e:
            latency_ms = (time.monotonic() - t0) * 1000
            result = ProbeResult(
                timestamp=time.time(),
                success=False,
                latency_ms=latency_ms,
                resolved_ip=resolved_ip,
                error=str(e)[:120],
            )
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass
                conn = None

        with lock:
            stats.results.append(result)

        # Live output
        ts = datetime.fromtimestamp(result.timestamp, tz=timezone.utc).strftime(
            "%H:%M:%S.%f"
        )[:12]
        if result.success:
            marker = "OK"
            backend = result.server_addr.split(":")[0] if result.server_addr else "?"
            detail = (
                f"conn={result.connection_id:<6}  "
                f"backend={backend:<8}  "
                f"{result.latency_ms:.0f}ms"
            )
        else:
            marker = "FAIL"
            detail = result.error[:50]

        # Detect events
        events = []
        if len(stats.results) >= 2 and result.success:
            prev_ok = [r for r in stats.results[:-1] if r.success]
            if prev_ok:
                prev = prev_ok[-1]
                if result.connection_id != prev.connection_id:
                    events.append(f"CONN_CHANGE {prev.connection_id}->{result.connection_id}")
                if result.server_addr and prev.server_addr and result.server_addr != prev.server_addr:
                    events.append(f"BACKEND_SWITCH {prev.server_addr}->{result.server_addr}")

        event_str = f"  *** {', '.join(events)}" if events else ""
        print(f"  [{ts}] {target.name:<10} #{probe_num:>3}  {marker:<4} {detail}{event_str}")

        time.sleep(interval)

    if conn:
        try:
            conn.close()
        except Exception:
            pass


def print_report(stats_list: list[ProbeStats]) -> bool:
    all_stable = True

    print(f"\n{'=' * 70}")
    print("  SWITCHOVER SMOKE TEST REPORT")
    print(f"{'=' * 70}")

    for stats in stats_list:
        stable = stats.endpoint_stable
        if not stable:
            all_stable = False

        print(f"\n  [{stats.target}] {stats.endpoint}")
        print(f"  {'─' * 60}")
        print(f"  Probes:        {stats.total} total, {stats.successes} ok, {stats.failures} failed")
        print(f"  Success rate:  {stats.success_rate:.1f}%")
        print(f"  Latency:       avg {stats.avg_latency_ms:.1f}ms  p99 {stats.p99_latency_ms:.1f}ms  max {stats.max_latency_ms:.1f}ms")
        print(f"  Max gap:       {stats.max_gap_seconds:.2f}s")
        print(f"  Conn IDs:      {len(stats.unique_conn_ids)} unique ({stats.conn_id_changes} changes)")
        print(f"  Backends:      {stats.unique_backends or 'n/a'} ({stats.backend_changes} switches)")
        print(f"  Endpoint DNS:  {'STABLE' if stable else 'CHANGED'} ({stats.unique_ips})")

        windows = stats.failure_windows
        if windows:
            print(f"  Failure windows:")
            for w in windows:
                t = datetime.fromtimestamp(w["start"], tz=timezone.utc).strftime("%H:%M:%S")
                print(f"    {t} — {w['duration_s']}s")

        if stats.backend_changes > 0:
            print(f"  Backend switchover timeline:")
            addrs = [(r.timestamp, r.server_addr) for r in stats.results if r.server_addr]
            for i in range(1, len(addrs)):
                if addrs[i][1] != addrs[i - 1][1]:
                    t = datetime.fromtimestamp(addrs[i][0], tz=timezone.utc).strftime("%H:%M:%S")
                    print(f"    {t}: {addrs[i - 1][1]} -> {addrs[i][1]}")

    # Comparison table (N-way)
    if len(stats_list) >= 2:
        col_w = 15
        names = [s.target for s in stats_list]
        header = f"  {'Metric':<25}" + "".join(f"{n:>{col_w}}" for n in names)
        sep = f"  {'─' * (25 + col_w * len(names))}"

        print(f"\n{sep}")
        print(f"  COMPARISON: {' vs '.join(names)}")
        print(sep)
        print(header)
        print(sep)

        def row(label, fmt, getter):
            vals = "".join(fmt(getter(s)) for s in stats_list)
            print(f"  {label:<25}{vals}")

        row("Success rate", lambda v: f"{v:>{col_w - 1}.1f}%", lambda s: s.success_rate)
        row("Avg latency", lambda v: f"{v:>{col_w - 2}.1f}ms", lambda s: s.avg_latency_ms)
        row("P99 latency", lambda v: f"{v:>{col_w - 2}.1f}ms", lambda s: s.p99_latency_ms)
        row("Max gap", lambda v: f"{v:>{col_w - 1}.2f}s", lambda s: s.max_gap_seconds)
        row("Conn ID changes", lambda v: f"{v:>{col_w}}", lambda s: s.conn_id_changes)
        row("Backend switches", lambda v: f"{v:>{col_w}}", lambda s: s.backend_changes)
        row("Failure windows", lambda v: f"{v:>{col_w}}", lambda s: len(s.failure_windows))
        row("Total failure time", lambda v: f"{v:>{col_w - 1}.2f}s",
            lambda s: sum(w["duration_s"] for w in s.failure_windows))

    # Verdict
    print(f"\n{'=' * 70}")
    if all_stable:
        print("  VERDICT: PASS — proxy endpoint(s) stable, no DNS changes")
    else:
        print("  VERDICT: WARN — endpoint resolution changed during test")
    print(f"{'=' * 70}\n")

    return all_stable


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
            "unique_backends": sorted(stats.unique_backends),
            "failure_windows": stats.failure_windows,
            "endpoint_stable": stats.endpoint_stable,
            "probes": [asdict(r) for r in stats.results],
        }

    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"  Results saved to {output_path}")


def parse_targets(args: list[str]) -> tuple[list[TargetConfig], float, float, str]:
    """Parse --target/--host/--port groups from argv."""
    parser = argparse.ArgumentParser(description="SQL Proxy Switchover Probe")
    parser.add_argument("--target", action="append", help="Target name (repeatable)")
    parser.add_argument("--host", action="append", help="Host for target (repeatable)")
    parser.add_argument("--port", action="append", type=int, help="Port for target (repeatable)")
    parser.add_argument("--user", default="root")
    parser.add_argument("--password", default="")
    parser.add_argument("--database", default="test")
    parser.add_argument("--duration", type=float, default=30)
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--output", default="")

    parsed = parser.parse_args(args)

    targets = []
    names = parsed.target or []
    hosts = parsed.host or []
    ports = parsed.port or []

    if not names:
        parser.error("At least one --target required")
    if len(names) != len(hosts) or len(names) != len(ports):
        parser.error("Each --target needs matching --host and --port")

    for name, host, port in zip(names, hosts, ports):
        targets.append(TargetConfig(
            name=name, host=host, port=port,
            user=parsed.user, password=parsed.password,
            database=parsed.database,
        ))

    return targets, parsed.duration, parsed.interval, parsed.output


def main():
    targets, duration, interval, output = parse_targets(sys.argv[1:])

    print(f"\n{'=' * 70}")
    print(f"  SQL Proxy Switchover Probe")
    print(f"  Targets: {', '.join(f'{t.name} ({t.host}:{t.port})' for t in targets)}")
    print(f"  Duration: {duration}s  Interval: {interval}s")
    print(f"{'=' * 70}")

    lock = threading.Lock()
    stats_list = []
    threads = []

    for target in targets:
        stats = ProbeStats(target=target.name, endpoint=f"{target.host}:{target.port}")
        stats_list.append(stats)
        t = threading.Thread(
            target=probe_loop,
            args=(target, duration, interval, stats, lock),
            daemon=True,
        )
        threads.append(t)

    for t in threads:
        t.start()
    for t in threads:
        t.join()

    all_stable = print_report(stats_list)

    if output:
        save_results(stats_list, output)

    sys.exit(0 if all_stable else 1)


if __name__ == "__main__":
    main()
