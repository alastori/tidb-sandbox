#!/usr/bin/env python3
"""Cloud DNS failover probe — resolves CNAME via CoreDNS, connects with TLS + SNI."""

import argparse
import json
import os
import sys
import time
from dataclasses import asdict, dataclass, field

import dns.resolver
import pymysql


@dataclass
class ProbeResult:
    timestamp: float
    cycle: int
    success: bool
    latency_ms: float = 0.0
    cname: str = ""
    resolved_ip: str = ""
    dns_ms: float = 0.0
    connect_ms: float = 0.0
    query_ms: float = 0.0
    connection_id: int | None = None
    cluster_name: str = ""
    tidb_version: str = ""
    error: str = ""
    reconnected: bool = False
    event: str = ""


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
        return (self.successes / self.total * 100) if self.total else 0

    @property
    def avg_latency_ms(self) -> float:
        ok = [r.latency_ms for r in self.results if r.success]
        return sum(ok) / len(ok) if ok else 0

    @property
    def max_latency_ms(self) -> float:
        ok = [r.latency_ms for r in self.results if r.success]
        return max(ok) if ok else 0

    @property
    def unique_cnames(self) -> set[str]:
        return {r.cname for r in self.results if r.cname}

    @property
    def unique_ips(self) -> set[str]:
        return {r.resolved_ip for r in self.results if r.resolved_ip}

    @property
    def cname_changes(self) -> int:
        changes = 0
        prev = None
        for r in self.results:
            if r.cname and prev and r.cname != prev:
                changes += 1
            if r.cname:
                prev = r.cname
        return changes

    @property
    def dns_flip_detected_at(self) -> float | None:
        prev = None
        for r in self.results:
            if r.cname and prev and r.cname != prev:
                return r.timestamp
            if r.cname:
                prev = r.cname
        return None

    @property
    def first_success_after_flip(self) -> float | None:
        flip_ts = self.dns_flip_detected_at
        if flip_ts is None:
            return None
        for r in self.results:
            if r.timestamp >= flip_ts and r.success:
                return r.timestamp
        return None

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
                windows.append(
                    {"start": start, "end": r.timestamp, "duration_s": round(r.timestamp - start, 2)}
                )
        if in_failure:
            windows.append(
                {
                    "start": start,
                    "end": self.results[-1].timestamp,
                    "duration_s": round(self.results[-1].timestamp - start, 2),
                }
            )
        return windows


def resolve_cname(hostname: str, dns_server: str, dns_port: int) -> tuple[str, str, float]:
    """Resolve hostname via CoreDNS, following CNAME chain.

    Returns (cname_target, resolved_ip, dns_ms).
    """
    t0 = time.monotonic()
    resolver = dns.resolver.Resolver(configure=False)
    resolver.nameservers = [dns_server]
    resolver.port = dns_port
    resolver.lifetime = 5.0

    cname = ""
    ip = ""

    # First, try to get the CNAME record
    try:
        cname_answer = resolver.resolve(hostname, "CNAME")
        cname = str(cname_answer[0].target).rstrip(".")
    except (dns.resolver.NoAnswer, dns.resolver.NXDOMAIN, dns.exception.DNSException):
        pass

    # If we got a CNAME, resolve it via system DNS (the CNAME target is a cloud endpoint)
    # CoreDNS forwards . to 8.8.8.8 which handles the cloud endpoint resolution
    if cname:
        try:
            a_answer = resolver.resolve(cname, "A")
            ip = str(a_answer[0].address)
        except dns.exception.DNSException:
            # Fallback: try resolving the original hostname as A record
            try:
                a_answer = resolver.resolve(hostname, "A")
                ip = str(a_answer[0].address)
            except dns.exception.DNSException:
                pass
    else:
        # No CNAME — try A record directly
        try:
            a_answer = resolver.resolve(hostname, "A")
            ip = str(a_answer[0].address)
        except dns.exception.DNSException:
            pass

    dns_ms = (time.monotonic() - t0) * 1000
    return cname, ip, dns_ms


def connect_mysql(
    host: str,
    port: int,
    user: str,
    password: str,
) -> pymysql.Connection:
    """Connect to TiDB Cloud with TLS (STARTTLS via MySQL protocol)."""
    return pymysql.connect(
        host=host,
        port=port,
        user=user,
        password=password,
        database="test",
        ssl={},
        connect_timeout=10,
        read_timeout=10,
    )


def probe_loop(
    target: str,
    probe_host: str,
    dns_server: str,
    dns_port: int,
    credentials: dict[str, dict],
    duration: int,
    interval: float,
    output: str | None,
) -> ProbeStats:
    """Main probe loop: resolve CNAME, connect with TLS, query."""

    stats = ProbeStats(target=target, endpoint=f"{probe_host} (via CoreDNS)")
    conn: pymysql.Connection | None = None
    prev_cname = ""
    cycle = 0

    start = time.monotonic()
    deadline = start + duration

    print(f"\n{'=' * 72}")
    print(f"  Probe: {target}")
    print(f"  Host:  {probe_host} → CoreDNS {dns_server}:{dns_port}")
    print(f"  Duration: {duration}s  Interval: {interval}s")
    print(f"  Credentials configured for: {', '.join(credentials.keys())}")
    print(f"{'=' * 72}\n")

    while time.monotonic() < deadline:
        cycle += 1
        t_cycle = time.monotonic()
        result = ProbeResult(timestamp=time.time(), cycle=cycle, success=False)
        event = ""

        # 1. DNS resolution
        try:
            cname, ip, dns_ms = resolve_cname(probe_host, dns_server, dns_port)
            result.cname = cname
            result.resolved_ip = ip
            result.dns_ms = round(dns_ms, 2)
        except Exception as e:
            result.error = f"DNS: {e}"
            stats.results.append(result)
            _log(result)
            time.sleep(max(0, interval - (time.monotonic() - t_cycle)))
            continue

        if not cname and not ip:
            result.error = "DNS: no CNAME or A record"
            stats.results.append(result)
            _log(result)
            time.sleep(max(0, interval - (time.monotonic() - t_cycle)))
            continue

        # 2. Detect DNS flip
        if prev_cname and cname and cname != prev_cname:
            event = f"DNS_FLIP {prev_cname} → {cname}"
            # Close old connection — new endpoint needs different credentials
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass
                conn = None
        if cname:
            prev_cname = cname

        # 3. Determine connection target + credentials
        connect_host = cname if cname else ip
        connect_port = 4000
        cred = credentials.get(connect_host)
        if not cred:
            result.error = f"No credentials for {connect_host}"
            result.event = event
            stats.results.append(result)
            _log(result)
            time.sleep(max(0, interval - (time.monotonic() - t_cycle)))
            continue

        # 4. Connect if needed
        if conn is None:
            try:
                t_conn = time.monotonic()
                conn = connect_mysql(
                    host=connect_host,
                    port=cred.get("port", connect_port),
                    user=cred["user"],
                    password=cred["password"],
                )
                result.connect_ms = round((time.monotonic() - t_conn) * 1000, 2)
                result.reconnected = True
            except Exception as e:
                result.error = f"Connect: {e}"
                result.event = event
                conn = None
                stats.results.append(result)
                _log(result)
                time.sleep(max(0, interval - (time.monotonic() - t_cycle)))
                continue

        # 5. Query
        try:
            t_q = time.monotonic()
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT CONNECTION_ID(), VERSION()"
                )
                row = cur.fetchone()
            result.query_ms = round((time.monotonic() - t_q) * 1000, 2)
            result.connection_id = row[0]
            result.tidb_version = row[1] or ""
            # Derive cluster_name from version: "-serverless" suffix = Essential
            ver = result.tidb_version
            if "-serverless" in ver:
                result.cluster_name = "essential"
            elif "TiDB" in ver:
                result.cluster_name = "dedicated"
            else:
                result.cluster_name = "unknown"
            result.success = True
        except Exception as e:
            result.error = f"Query: {e}"
            # Connection might be stale — close it for retry
            try:
                conn.close()
            except Exception:
                pass
            conn = None

        result.event = event
        result.latency_ms = round((time.monotonic() - t_cycle) * 1000, 2)
        stats.results.append(result)
        _log(result)

        elapsed = time.monotonic() - t_cycle
        time.sleep(max(0, interval - elapsed))

    # Close final connection
    if conn:
        try:
            conn.close()
        except Exception:
            pass

    print_report(stats)
    if output:
        save_results(stats, output)

    return stats


def _log(r: ProbeResult) -> None:
    """Print one-line probe result."""
    status = "[OK]" if r.success else "[FAIL]"
    recon = " [R]" if r.reconnected else ""
    cname_short = r.cname.split(".")[0] if r.cname else "?"
    cluster = r.cluster_name or "?"

    parts = [
        f"#{r.cycle:>4d}",
        status,
        f"dns={r.dns_ms:>6.1f}ms",
    ]
    if r.connect_ms:
        parts.append(f"conn={r.connect_ms:>6.1f}ms")
    if r.query_ms:
        parts.append(f"qry={r.query_ms:>5.1f}ms")
    parts.append(f"cname={cname_short}")
    parts.append(f"cluster={cluster}")
    if r.error:
        parts.append(f"err={r.error[:60]}")
    if r.event:
        parts.append(f"*** {r.event}")
    parts.append(recon)

    print(" | ".join(parts), flush=True)


def print_report(stats: ProbeStats) -> None:
    """Print summary report."""
    print(f"\n{'=' * 72}")
    print(f"  Report: {stats.target}")
    print(f"{'=' * 72}")
    print(f"  Probes: {stats.total}  OK: {stats.successes}  FAIL: {stats.failures}")
    print(f"  Success rate: {stats.success_rate:.1f}%")
    print(f"  Latency (avg): {stats.avg_latency_ms:.1f}ms  (max): {stats.max_latency_ms:.1f}ms")
    print(f"  Unique CNAMEs: {stats.unique_cnames}")
    print(f"  Unique IPs: {stats.unique_ips}")
    print(f"  CNAME changes: {stats.cname_changes}")

    flip_ts = stats.dns_flip_detected_at
    if flip_ts:
        first_ok = stats.first_success_after_flip
        if first_ok:
            delta = first_ok - flip_ts
            print(f"  DNS flip detected at: {flip_ts:.3f}")
            print(f"  First success after flip: {first_ok:.3f} (+{delta:.2f}s)")
        else:
            print(f"  DNS flip detected at: {flip_ts:.3f}")
            print("  No successful probe after flip!")

    if stats.failure_windows:
        print("  Failure windows:")
        for w in stats.failure_windows:
            print(f"    {w['duration_s']:.2f}s")

    print(f"{'=' * 72}\n")


def save_results(stats: ProbeStats, output_path: str) -> None:
    """Save results as JSONL."""
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w") as f:
        for r in stats.results:
            f.write(json.dumps(asdict(r)) + "\n")
    print(f"  Results saved to {output_path} ({len(stats.results)} records)")

    # Also save summary
    summary_path = output_path.replace(".jsonl", "-summary.json")
    if summary_path == output_path:
        summary_path = output_path + ".summary.json"
    summary = {
        "target": stats.target,
        "endpoint": stats.endpoint,
        "total": stats.total,
        "successes": stats.successes,
        "failures": stats.failures,
        "success_rate": stats.success_rate,
        "avg_latency_ms": stats.avg_latency_ms,
        "max_latency_ms": stats.max_latency_ms,
        "unique_cnames": list(stats.unique_cnames),
        "unique_ips": list(stats.unique_ips),
        "cname_changes": stats.cname_changes,
        "failure_windows": stats.failure_windows,
        "dns_flip_detected_at": stats.dns_flip_detected_at,
        "first_success_after_flip": stats.first_success_after_flip,
    }
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"  Summary saved to {summary_path}")


def build_credentials(env: dict) -> dict[str, dict]:
    """Build hostname → {user, password, port} map from environment."""
    creds = {}
    if env.get("DEDICATED_HOST"):
        creds[env["DEDICATED_HOST"]] = {
            "user": env.get("DEDICATED_USER", "root"),
            "password": env.get("DEDICATED_PASSWORD", ""),
            "port": int(env.get("DEDICATED_PORT", "4000")),
        }
    if env.get("ESSENTIAL_HOST"):
        creds[env["ESSENTIAL_HOST"]] = {
            "user": env.get("ESSENTIAL_USER", ""),
            "password": env.get("ESSENTIAL_PASSWORD", ""),
            "port": int(env.get("ESSENTIAL_PORT", "4000")),
        }
    return creds


def main():
    parser = argparse.ArgumentParser(description="Cloud DNS failover probe")
    parser.add_argument("--target", default="cloud-dns", help="Test name")
    parser.add_argument("--host", default="db.tidb.lab", help="Hostname to resolve via CoreDNS")
    parser.add_argument("--dns-server", default="172.30.0.10", help="CoreDNS IP")
    parser.add_argument("--dns-port", type=int, default=53, help="CoreDNS port")
    parser.add_argument("--duration", type=int, default=60, help="Probe duration (seconds)")
    parser.add_argument("--interval", type=float, default=2.0, help="Probe interval (seconds)")
    parser.add_argument("--output", help="Output JSONL path")
    args = parser.parse_args()

    credentials = build_credentials(os.environ)
    if not credentials:
        print("ERROR: No credentials configured. Set DEDICATED_HOST/ESSENTIAL_HOST in .env")
        sys.exit(1)

    print(f"Credential map: {list(credentials.keys())}")

    probe_loop(
        target=args.target,
        probe_host=args.host,
        dns_server=args.dns_server,
        dns_port=args.dns_port,
        credentials=credentials,
        duration=args.duration,
        interval=args.interval,
        output=args.output,
    )


if __name__ == "__main__":
    main()
