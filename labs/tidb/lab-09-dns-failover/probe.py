#!/usr/bin/env python3
"""DNS failover probe — measures client behavior during DNS resolution changes.

Unlike Lab 08's proxy probe, this one:
- Resolves the hostname via a custom DNS server (CoreDNS) on each probe
- Tracks which IP the hostname resolves to over time
- Detects when resolution changes (DNS flip)
- Measures how long the client takes to connect to the new IP
- Supports both persistent (reuse) and reconnect-each-time modes

Requires: pymysql

Usage:
    python3 probe.py \
        --target dns-tidb --host tidb.lab --port 4000 \
        --dns-server 127.0.0.1:5300 \
        --duration 30 --interval 0.5
"""

from __future__ import annotations

import argparse
import json
import socket
import subprocess
import sys
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
    resolved_ip: str = ""
    hostname_backend: str = ""  # @@hostname — which container answered
    error: str = ""
    reconnected: bool = False  # True if a new connection was created this probe


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
    def max_latency_ms(self) -> float:
        lats = [r.latency_ms for r in self.results if r.success]
        return max(lats) if lats else 0.0

    @property
    def unique_ips(self) -> set[str]:
        return {r.resolved_ip for r in self.results if r.resolved_ip}

    @property
    def unique_backends(self) -> set[str]:
        return {r.hostname_backend for r in self.results if r.hostname_backend}

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
    def ip_changes(self) -> int:
        ips = [r.resolved_ip for r in self.results if r.resolved_ip]
        return sum(1 for i in range(1, len(ips)) if ips[i] != ips[i - 1])

    @property
    def backend_changes(self) -> int:
        addrs = [r.hostname_backend for r in self.results if r.hostname_backend]
        return sum(1 for i in range(1, len(addrs)) if addrs[i] != addrs[i - 1])

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

    @property
    def dns_flip_detected_at(self) -> float | None:
        """Timestamp when resolved IP first changed."""
        ips = [(r.timestamp, r.resolved_ip) for r in self.results if r.resolved_ip]
        for i in range(1, len(ips)):
            if ips[i][1] != ips[i - 1][1]:
                return ips[i][0]
        return None

    @property
    def first_success_on_new_ip(self) -> float | None:
        """Timestamp of first successful query after DNS flip."""
        flip_ts = self.dns_flip_detected_at
        if flip_ts is None:
            return None
        ips = [(r.timestamp, r.resolved_ip) for r in self.results if r.resolved_ip]
        if len(ips) < 2:
            return None
        new_ip = None
        for i in range(1, len(ips)):
            if ips[i][1] != ips[i - 1][1]:
                new_ip = ips[i][1]
                break
        if new_ip is None:
            return None
        for r in self.results:
            if r.success and r.resolved_ip == new_ip and r.timestamp >= flip_ts:
                return r.timestamp
        return None


def resolve_via_dns(hostname: str, dns_server: str | None) -> str:
    """Resolve hostname, optionally via custom DNS server."""
    if dns_server:
        try:
            parts = dns_server.split(":")
            server = parts[0]
            port = parts[1] if len(parts) > 1 else "53"
            result = subprocess.run(
                ["dig", "+short", "+tcp", f"@{server}", "-p", port, hostname, "A"],
                capture_output=True, text=True, timeout=3,
            )
            if result.returncode != 0 and result.stderr.strip():
                print(f"  [dns] dig error: {result.stderr.strip()}", file=sys.stderr)
            ip = result.stdout.strip().split("\n")[0]
            return ip if ip else "unresolved"
        except Exception as e:
            print(f"  [dns] resolve error: {e}", file=sys.stderr)
            return "unresolved"
    else:
        try:
            return socket.gethostbyname(hostname)
        except socket.gaierror:
            return "unresolved"


def probe_loop(
    target_name: str,
    host: str,
    port: int,
    user: str,
    password: str,
    database: str,
    dns_server: str | None,
    reconnect_each: bool,
    duration: float,
    interval: float,
    stats: ProbeStats,
):
    """Run probes for the given duration."""
    conn = None
    end_time = time.monotonic() + duration
    probe_num = 0
    last_resolved_ip = None

    while time.monotonic() < end_time:
        probe_num += 1
        t0 = time.monotonic()

        # Resolve DNS each time to detect changes
        resolved_ip = resolve_via_dns(host, dns_server)
        reconnected = False

        try:
            # Reconnect if: no connection, reconnect mode, or IP changed
            need_reconnect = (
                conn is None
                or reconnect_each
                or (resolved_ip != last_resolved_ip and last_resolved_ip is not None)
            )

            if need_reconnect and conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass
                conn = None

            if conn is None:
                connect_ip = resolved_ip if resolved_ip != "unresolved" else host
                conn = pymysql.connect(
                    host=connect_ip,
                    port=port,
                    user=user,
                    password=password,
                    database=database,
                    connect_timeout=5,
                    read_timeout=5,
                )
                reconnected = True
            else:
                try:
                    conn.ping(reconnect=False)
                except Exception:
                    connect_ip = resolved_ip if resolved_ip != "unresolved" else host
                    conn = pymysql.connect(
                        host=connect_ip,
                        port=port,
                        user=user,
                        password=password,
                        database=database,
                        connect_timeout=5,
                        read_timeout=5,
                    )
                    reconnected = True

            with conn.cursor() as cur:
                cur.execute("SELECT CONNECTION_ID(), @@version, @@hostname")
                row = cur.fetchone()

            latency_ms = (time.monotonic() - t0) * 1000
            result = ProbeResult(
                timestamp=time.time(),
                success=True,
                latency_ms=latency_ms,
                connection_id=row[0],
                resolved_ip=resolved_ip,
                hostname_backend=row[2] if row[2] else "",
                reconnected=reconnected,
            )
            last_resolved_ip = resolved_ip

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
            last_resolved_ip = resolved_ip

        stats.results.append(result)

        # Live output
        ts = datetime.fromtimestamp(result.timestamp, tz=timezone.utc).strftime(
            "%H:%M:%S.%f"
        )[:12]
        if result.success:
            marker = "OK"
            reconn = "R" if result.reconnected else " "
            detail = (
                f"[{reconn}] ip={result.resolved_ip:<15} "
                f"backend={result.hostname_backend:<14} "
                f"conn={result.connection_id:<6} "
                f"{result.latency_ms:.0f}ms"
            )
        else:
            marker = "FAIL"
            detail = f"    ip={result.resolved_ip:<15} {result.error[:40]}"

        # Detect events
        events = []
        if len(stats.results) >= 2:
            prev = stats.results[-2]
            if result.resolved_ip != prev.resolved_ip and prev.resolved_ip:
                events.append(f"DNS_FLIP {prev.resolved_ip}->{result.resolved_ip}")
            if (
                result.success and prev.success
                and result.hostname_backend != prev.hostname_backend
                and prev.hostname_backend
            ):
                events.append(f"BACKEND_CHANGE {prev.hostname_backend}->{result.hostname_backend}")

        event_str = f"  *** {', '.join(events)}" if events else ""
        print(f"  [{ts}] {target_name:<10} #{probe_num:>3}  {marker:<4} {detail}{event_str}")

        if reconnect_each and conn:
            try:
                conn.close()
            except Exception:
                pass
            conn = None

        time.sleep(interval)

    if conn:
        try:
            conn.close()
        except Exception:
            pass


def print_report(stats_list: list[ProbeStats]) -> bool:
    print(f"\n{'=' * 70}")
    print("  DNS FAILOVER SMOKE TEST REPORT")
    print(f"{'=' * 70}")

    for stats in stats_list:
        print(f"\n  [{stats.target}] {stats.endpoint}")
        print(f"  {'─' * 60}")
        print(f"  Probes:        {stats.total} total, {stats.successes} ok, {stats.failures} failed")
        print(f"  Success rate:  {stats.success_rate:.1f}%")
        print(f"  Latency:       avg {stats.avg_latency_ms:.1f}ms  max {stats.max_latency_ms:.1f}ms")
        print(f"  Max gap:       {stats.max_gap_seconds:.2f}s")
        print(f"  Resolved IPs:  {stats.unique_ips} ({stats.ip_changes} changes)")
        print(f"  Backends:      {stats.unique_backends} ({stats.backend_changes} changes)")

        flip_ts = stats.dns_flip_detected_at
        success_ts = stats.first_success_on_new_ip
        if flip_ts and success_ts:
            migration_time = success_ts - flip_ts
            flip_str = datetime.fromtimestamp(flip_ts, tz=timezone.utc).strftime("%H:%M:%S")
            ok_str = datetime.fromtimestamp(success_ts, tz=timezone.utc).strftime("%H:%M:%S")
            print(f"  DNS flip seen: {flip_str}")
            print(f"  New IP works:  {ok_str} ({migration_time:.2f}s after flip)")
        elif flip_ts:
            flip_str = datetime.fromtimestamp(flip_ts, tz=timezone.utc).strftime("%H:%M:%S")
            print(f"  DNS flip seen: {flip_str} (never connected to new IP)")

        windows = stats.failure_windows
        if windows:
            print(f"  Failure windows:")
            for w in windows:
                t = datetime.fromtimestamp(w["start"], tz=timezone.utc).strftime("%H:%M:%S")
                print(f"    {t} — {w['duration_s']}s")

    print(f"\n{'=' * 70}\n")
    return True


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
            "max_latency_ms": round(stats.max_latency_ms, 2),
            "max_gap_s": round(stats.max_gap_seconds, 3),
            "ip_changes": stats.ip_changes,
            "backend_changes": stats.backend_changes,
            "unique_ips": sorted(stats.unique_ips),
            "unique_backends": sorted(stats.unique_backends),
            "failure_windows": stats.failure_windows,
            "probes": [asdict(r) for r in stats.results],
        }

    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"  Results saved to {output_path}")


def main():
    parser = argparse.ArgumentParser(description="DNS Failover Probe")
    parser.add_argument("--target", action="append", help="Target name (repeatable)")
    parser.add_argument("--host", action="append", help="Hostname (repeatable)")
    parser.add_argument("--port", action="append", type=int, help="Port (repeatable)")
    parser.add_argument("--user", default="root")
    parser.add_argument("--password", default="")
    parser.add_argument("--database", default="test")
    parser.add_argument("--dns-server", default=None, help="Custom DNS server (host:port)")
    parser.add_argument("--reconnect-each", action="store_true",
                        help="Close and reconnect on every probe (test fresh resolution)")
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

    print(f"\n{'=' * 70}")
    print(f"  DNS Failover Probe")
    print(f"  DNS server: {args.dns_server or 'system default'}")
    print(f"  Duration: {args.duration}s  Interval: {args.interval}s")
    print(f"  Reconnect each: {args.reconnect_each}")
    print(f"{'=' * 70}")

    stats_list = []
    for name, host, port in zip(names, hosts, ports):
        stats = ProbeStats(target=name, endpoint=f"{host}:{port}")
        stats_list.append(stats)

        probe_loop(
            target_name=name,
            host=host,
            port=port,
            user=args.user,
            password=args.password,
            database=args.database,
            dns_server=args.dns_server,
            reconnect_each=args.reconnect_each,
            duration=args.duration,
            interval=args.interval,
            stats=stats,
        )

    print_report(stats_list)

    if args.output:
        save_results(stats_list, args.output)

    sys.exit(0)


if __name__ == "__main__":
    main()
