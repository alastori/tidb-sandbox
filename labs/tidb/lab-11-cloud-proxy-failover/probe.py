#!/usr/bin/env python3
"""Proxy failover probe — connects through proxy, detects backend via VERSION()."""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from dataclasses import asdict, dataclass, field

import pymysql


@dataclass
class ProbeResult:
    timestamp: float
    cycle: int
    success: bool
    latency_ms: float = 0.0
    connect_ms: float = 0.0
    query_ms: float = 0.0
    connection_id: int | None = None
    tidb_version: str = ""
    backend: str = ""
    error: str = ""
    reconnected: bool = False
    event: str = ""


@dataclass
class ProbeStats:
    target: str
    endpoint: str
    results: list[ProbeResult] = field(default_factory=list)

    @property
    def total(self): return len(self.results)
    @property
    def successes(self): return sum(1 for r in self.results if r.success)
    @property
    def failures(self): return self.total - self.successes
    @property
    def success_rate(self): return (self.successes / self.total * 100) if self.total else 0
    @property
    def avg_latency_ms(self):
        ok = [r.latency_ms for r in self.results if r.success]
        return sum(ok) / len(ok) if ok else 0
    @property
    def max_latency_ms(self):
        ok = [r.latency_ms for r in self.results if r.success]
        return max(ok) if ok else 0
    @property
    def backend_changes(self):
        changes, prev = 0, None
        for r in self.results:
            if r.backend and prev and r.backend != prev: changes += 1
            if r.backend: prev = r.backend
        return changes
    @property
    def conn_id_changes(self):
        changes, prev = 0, None
        for r in self.results:
            if r.connection_id and prev and r.connection_id != prev: changes += 1
            if r.connection_id: prev = r.connection_id
        return changes
    @property
    def switch_detected_at(self):
        prev = None
        for r in self.results:
            if r.backend and prev and r.backend != prev: return r.timestamp
            if r.backend: prev = r.backend
        return None
    @property
    def first_success_after_switch(self):
        ts = self.switch_detected_at
        if ts is None: return None
        for r in self.results:
            if r.timestamp >= ts and r.success: return r.timestamp
        return None
    @property
    def failure_windows(self):
        windows, in_failure, start = [], False, 0.0
        for r in self.results:
            if not r.success and not in_failure: in_failure, start = True, r.timestamp
            elif r.success and in_failure:
                in_failure = False
                windows.append({"start": start, "end": r.timestamp, "duration_s": round(r.timestamp - start, 2)})
        if in_failure and self.results:
            windows.append({"start": start, "end": self.results[-1].timestamp, "duration_s": round(self.results[-1].timestamp - start, 2)})
        return windows


def detect_backend(version):
    if "-serverless" in version: return "essential"
    elif "TiDB" in version: return "dedicated"
    return "unknown"


def probe_loop(target, host, port, user, password, use_ssl, duration, interval, output):
    stats = ProbeStats(target=target, endpoint=f"{host}:{port}")
    conn = None
    prev_backend, prev_conn_id, cycle = "", None, 0
    ssl_opts = {} if use_ssl else None

    start = time.monotonic()
    deadline = start + duration

    print(f"\n{'='*72}")
    print(f"  Probe: {target}")
    print(f"  Proxy: {host}:{port}  SSL: {use_ssl}")
    print(f"  Duration: {duration}s  Interval: {interval}s")
    print(f"{'='*72}\n")

    while time.monotonic() < deadline:
        cycle += 1
        t_cycle = time.monotonic()
        result = ProbeResult(timestamp=time.time(), cycle=cycle, success=False)
        events = []

        if conn is None:
            try:
                t_conn = time.monotonic()
                conn = pymysql.connect(host=host, port=port, user=user, password=password,
                                       ssl=ssl_opts, connect_timeout=10, read_timeout=10)
                result.connect_ms = round((time.monotonic() - t_conn) * 1000, 2)
                result.reconnected = True
            except Exception as e:
                result.error = f"Connect: {e}"
                result.latency_ms = round((time.monotonic() - t_cycle) * 1000, 2)
                stats.results.append(result)
                _log(result)
                time.sleep(max(0, interval - (time.monotonic() - t_cycle)))
                continue

        try:
            t_q = time.monotonic()
            with conn.cursor() as cur:
                cur.execute("SELECT CONNECTION_ID(), VERSION()")
                row = cur.fetchone()
            result.query_ms = round((time.monotonic() - t_q) * 1000, 2)
            result.connection_id = row[0]
            result.tidb_version = row[1] or ""
            result.backend = detect_backend(result.tidb_version)
            result.success = True
        except Exception as e:
            result.error = f"Query: {e}"
            try: conn.close()
            except Exception: pass
            conn = None

        if result.success:
            if prev_backend and result.backend != prev_backend:
                events.append(f"BACKEND_SWITCH {prev_backend}->{result.backend}")
            if prev_conn_id and result.connection_id != prev_conn_id:
                events.append("CONN_CHANGE")
            prev_backend = result.backend
            prev_conn_id = result.connection_id

        result.event = " | ".join(events)
        result.latency_ms = round((time.monotonic() - t_cycle) * 1000, 2)
        stats.results.append(result)
        _log(result)
        time.sleep(max(0, interval - (time.monotonic() - t_cycle)))

    if conn:
        try: conn.close()
        except Exception: pass

    print_report(stats)
    if output: save_results(stats, output)
    return stats


def _log(r):
    status = "[OK]" if r.success else "[FAIL]"
    recon = " [R]" if r.reconnected else ""
    parts = [f"#{r.cycle:>4d}", status]
    if r.connect_ms: parts.append(f"conn={r.connect_ms:>6.1f}ms")
    if r.query_ms: parts.append(f"qry={r.query_ms:>5.1f}ms")
    parts.append(f"backend={r.backend or '?'}")
    if r.error: parts.append(f"err={r.error[:50]}")
    if r.event: parts.append(f"*** {r.event}")
    parts.append(recon)
    print(" | ".join(parts), flush=True)


def print_report(stats):
    print(f"\n{'='*72}")
    print(f"  Report: {stats.target}")
    print(f"{'='*72}")
    print(f"  Probes: {stats.total}  OK: {stats.successes}  FAIL: {stats.failures}")
    print(f"  Success rate: {stats.success_rate:.1f}%")
    print(f"  Latency (avg): {stats.avg_latency_ms:.1f}ms  (max): {stats.max_latency_ms:.1f}ms")
    print(f"  Backend changes: {stats.backend_changes}")
    print(f"  Connection ID changes: {stats.conn_id_changes}")
    ts = stats.switch_detected_at
    if ts:
        first_ok = stats.first_success_after_switch
        if first_ok: print(f"  Switch detected at: {ts:.3f}\n  First success after switch: +{first_ok - ts:.2f}s")
        else: print(f"  Switch detected at: {ts:.3f}, no success after!")
    if stats.failure_windows:
        print("  Failure windows:")
        for w in stats.failure_windows: print(f"    {w['duration_s']:.2f}s")
    print(f"{'='*72}\n")


def save_results(stats, output_path):
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w") as f:
        for r in stats.results: f.write(json.dumps(asdict(r)) + "\n")
    print(f"  Results saved to {output_path} ({len(stats.results)} records)")
    summary_path = output_path.replace(".jsonl", "-summary.json")
    if summary_path == output_path:
        summary_path = output_path + ".summary.json"
    summary = {
        "target": stats.target, "endpoint": stats.endpoint,
        "total": stats.total, "successes": stats.successes, "failures": stats.failures,
        "success_rate": stats.success_rate, "avg_latency_ms": stats.avg_latency_ms,
        "max_latency_ms": stats.max_latency_ms, "backend_changes": stats.backend_changes,
        "conn_id_changes": stats.conn_id_changes, "failure_windows": stats.failure_windows,
        "switch_detected_at": stats.switch_detected_at, "first_success_after_switch": stats.first_success_after_switch,
    }
    with open(summary_path, "w") as f: json.dump(summary, f, indent=2)
    print(f"  Summary saved to {summary_path}")


def main():
    p = argparse.ArgumentParser(description="Proxy failover probe")
    p.add_argument("--target", default="proxy")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--user", required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--ssl", action="store_true")
    p.add_argument("--duration", type=int, default=60)
    p.add_argument("--interval", type=float, default=2.0)
    p.add_argument("--output")
    args = p.parse_args()
    probe_loop(target=args.target, host=args.host, port=args.port, user=args.user,
               password=args.password, use_ssl=args.ssl, duration=args.duration,
               interval=args.interval, output=args.output)


if __name__ == "__main__":
    main()
