#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Summarize JUnit results for a single Jenkins build, grouped by a chosen
Pipeline label from `suite.enclosingBlockNames[label_index]`.

Flow:
1) Resolve job URL → concrete build (number / lastBuild / lastSuccessfulBuild)
2) Fetch build metadata (timestamp/result/url)
3) Fetch trimmed JUnit report (duration, suites[], cases[].status, enclosingBlockNames)
4) Aggregate by pipeline label and print summary/table (+ optional JSON)
5) [Optional with --with-gradle-tasks] Use WFAPI to correlate suites with Gradle tasks
"""

import argparse
import datetime as dt
import json
import re
import sys
import urllib.error
import urllib.request
from typing import Dict, Tuple, Optional, List, Set

UA = "jenkins-junit-pipeline-label-summary/1.5"
TIMEOUT = 30
ALL_STATUSES = ["PASSED", "SKIPPED", "FAILED", "FIXED", "REGRESSION"]
VERBOSE = False

# Match Gradle task lines (from jenkins_pipeline_tasks_summary.py)
TASK_RE = re.compile(r'^(?:&gt;|>)(?:<b[^>]*>)?\s*Task\s+(:[A-Za-z0-9_-]+(?::[A-Za-z0-9_-]+)*:test)\b')

# --- HTTP ---
def http_get(url: str, expect_json: bool = False):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        data = r.read()
    if expect_json:
        try:
            return json.loads(data.decode("utf-8", "replace"))
        except Exception:
            return None
    return data.decode("utf-8", "replace")

def http_get_json(url: str, ignore_404: bool = False) -> Optional[dict]:
    """
    Fetch JSON from a URL. Returns None on error.
    If ignore_404=True, will log and return None on 404 instead of raising.
    """
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            data = r.read()
        return json.loads(data.decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            if ignore_404:
                if VERBOSE:
                    print(f"  [404] {url}", file=sys.stderr)
                return None
            raise
        raise
    except Exception as e:
        if VERBOSE:
            print(f"  [ERROR] {url}: {e}", file=sys.stderr)
        return None

# --- Build URL pinning ---
def normalize_job_or_build_url(url: str) -> str:
    u = url.rstrip("/")
    parts = u.split("/")
    # Check if URL already points to a build (numeric or lastBuild/lastSuccessfulBuild)
    if parts and (parts[-1].isdigit() or parts[-1] in ("lastBuild", "lastSuccessfulBuild")):
        return u  # already a specific build
    return u      # job URL (we'll append a spec)

def pin_build(url: str, build_spec: str) -> str:
    u = normalize_job_or_build_url(url)
    parts = u.split("/")
    # If already pinned to a build, return as-is
    if parts and (parts[-1].isdigit() or parts[-1] in ("lastBuild", "lastSuccessfulBuild")):
        return u
    return u + "/" + build_spec  # "lastBuild", "lastSuccessfulBuild", or number

# --- Jenkins fetches ---
def fetch_build_info(build_url: str) -> Optional[dict]:
    url = f"{build_url.rstrip('/')}/api/json?tree=timestamp,result,number,url,displayName"
    return http_get(url, expect_json=True)

def fetch_test_report(build_url: str) -> Optional[dict]:
    url = (
        f"{build_url.rstrip('/')}/testReport/api/json"
        "?tree=duration,suites[duration,cases[status],enclosingBlockNames,nodeId]"
    )
    return http_get(url, expect_json=True)

# --- Parsing & aggregation ---
def parse_test_report(report: dict, label_index: int) -> Tuple[dict, Dict[str, dict]]:
    overall = {"suites": 0, "cases": 0, "duration": 0.0}
    labels: Dict[str, dict] = {}

    if not report or "suites" not in report:
        return overall, labels

    overall["duration"] = float(report.get("duration", 0.0))
    suites = report.get("suites", [])
    overall["suites"] = len(suites)

    for suite in suites:
        blocks = suite.get("enclosingBlockNames", []) or []
        try:
            label = blocks[label_index]
        except Exception:
            continue

        bucket = labels.setdefault(label, {"cases": 0, "duration": 0.0, "suites": 0})
        bucket["duration"] += float(suite.get("duration", 0.0))
        bucket["suites"] += 1

        for case in suite.get("cases", []) or []:
            overall["cases"] += 1
            bucket["cases"] += 1
            status = case.get("status")
            if status not in ALL_STATUSES:
                bucket["UNKNOWN"] = bucket.get("UNKNOWN", 0) + 1
            else:
                bucket[status] = bucket.get(status, 0) + 1

    return overall, labels

# --- WFAPI helpers (for --with-gradle-tasks) ---
def wfapi_log_lines(build_url: str, node_id: str) -> List[str]:
    """
    Get log lines for a node. Returns empty list if endpoint fails.
    Uses the console log endpoint to get complete logs.
    """
    url = build_url.rstrip("/") + f"/execution/node/{node_id}/log"
    if VERBOSE:
        print(f"  Fetching logs for node {node_id}: {url}", file=sys.stderr)

    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            data = r.read()
        text = data.decode("utf-8", "replace")
        return text.splitlines()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            if VERBOSE:
                print(f"  [404] {url}", file=sys.stderr)
            return []
        if VERBOSE:
            print(f"  [HTTP {e.code}] {url}", file=sys.stderr)
        return []
    except Exception as e:
        if VERBOSE:
            print(f"  [ERROR] {url}: {e}", file=sys.stderr)
        return []

def extract_gradle_tasks_from_logs(lines: List[str]) -> List[str]:
    """
    Extract Gradle :*:test tasks from log lines.
    Returns a list of unique task paths found.
    """
    tasks: Set[str] = set()
    for ln in lines:
        m = TASK_RE.match(ln)
        if m:
            tasks.add(m.group(1))
    return sorted(tasks)

def correlate_suites_with_gradle_tasks(build_url: str, report: dict) -> Dict[int, List[str]]:
    """
    Map suite index → list of Gradle tasks by fetching WFAPI logs for each suite's nodeId.
    Returns dict mapping suite index to list of task paths.

    Optimization: Deduplicates by nodeId to avoid fetching the same logs multiple times.
    Many suites share the same pipeline node.
    """
    suite_tasks: Dict[int, List[str]] = {}

    if not report or "suites" not in report:
        return suite_tasks

    suites = report.get("suites", [])

    # Phase 1: Group suites by nodeId to deduplicate log fetches
    node_to_suites: Dict[str, List[int]] = {}
    for idx, suite in enumerate(suites):
        node_id = suite.get("nodeId")
        if node_id:
            node_id_str = str(node_id)
            if node_id_str not in node_to_suites:
                node_to_suites[node_id_str] = []
            node_to_suites[node_id_str].append(idx)

    total_nodes = len(node_to_suites)
    if VERBOSE:
        print(f"  Found {len(suites)} suites across {total_nodes} unique nodes", file=sys.stderr)

    # Phase 2: Fetch logs once per unique nodeId
    node_tasks_cache: Dict[str, List[str]] = {}
    processed = 0

    for node_id, suite_indices in node_to_suites.items():
        processed += 1

        # Progress indicator (verbose: every 100, non-verbose: every 500)
        if VERBOSE:
            if processed % 100 == 0:
                print(f"  Progress: {processed}/{total_nodes} nodes processed", file=sys.stderr)
        else:
            if processed % 500 == 0 or processed == total_nodes:
                pct = int(100 * processed / total_nodes)
                print(f"  Progress: {processed}/{total_nodes} nodes ({pct}%)", file=sys.stderr)

        try:
            lines = wfapi_log_lines(build_url, node_id)
            tasks = extract_gradle_tasks_from_logs(lines)
            if tasks:
                node_tasks_cache[node_id] = tasks
                if VERBOSE:
                    print(f"  Node {node_id}: found tasks {tasks} (used by {len(suite_indices)} suite(s))", file=sys.stderr)
        except Exception as e:
            if VERBOSE:
                print(f"  Node {node_id}: error fetching logs: {e}", file=sys.stderr)

    # Phase 3: Map tasks back to suite indices
    for node_id, suite_indices in node_to_suites.items():
        if node_id in node_tasks_cache:
            tasks = node_tasks_cache[node_id]
            for suite_idx in suite_indices:
                suite_tasks[suite_idx] = tasks

    return suite_tasks

# --- Formatting ---
def format_duration(seconds: float) -> str:
    if seconds <= 0:
        return "0s"
    td = dt.timedelta(seconds=int(seconds))
    h, rem = divmod(int(td.total_seconds()), 3600)
    m, s = divmod(rem, 60)
    parts = []
    if h: parts.append(f"{h}h")
    if m: parts.append(f"{m}m")
    if s or not parts: parts.append(f"{s}s")
    return " ".join(parts)

# --- CLI ---
def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    """Parse CLI arguments for the pipeline-label summary."""
    ap = argparse.ArgumentParser(
        description=("Summarize JUnit results by pipeline label "
                     "(suite.enclosingBlockNames[label_index]).")
    )
    ap.add_argument("url", help="Job or build URL")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--last", action="store_true", help="Use lastBuild (default if job URL)")
    g.add_argument("--last-success", action="store_true", help="Use lastSuccessfulBuild")
    ap.add_argument("--build", metavar="N", help="Pin to build number N")
    ap.add_argument("--label-index", type=int, default=-2,
                    help="Index into enclosingBlockNames to use as the pipeline label (default: -2)")
    ap.add_argument("--with-gradle-tasks", action="store_true",
                    help="Use WFAPI to correlate JUnit suites with their originating Gradle tasks")
    ap.add_argument("--json-out", help="Write JSON summary to this path")
    ap.add_argument("--verbose", "-v", action="store_true", help="Enable verbose output for debugging")
    return ap.parse_args(argv)


def run(args: argparse.Namespace) -> dict:
    """Execute the pipeline-label summary workflow and return summary metadata."""
    global VERBOSE

    VERBOSE = args.verbose
    base = normalize_job_or_build_url(args.url)
    parts = base.split("/")
    # Determine if URL is already pinned
    if parts and (parts[-1].isdigit() or parts[-1] in ("lastBuild", "lastSuccessfulBuild")):
        build_url = base
        if parts[-1].isdigit():
            pin_spec = "(pinned build number)"
        else:
            pin_spec = f"({parts[-1]})"
    else:
        spec = "lastBuild"
        if args.last_success: spec = "lastSuccessfulBuild"
        if args.build: spec = args.build
        build_url = pin_build(base, spec)
        pin_spec = spec

    # 1) Start banner
    print("Starting JUnit pipeline-label summary…")
    print(f"  Input URL:        {args.url}")
    print(f"  Resolved build:   {build_url}  [{pin_spec}]")
    print(f"  Label index:      {args.label_index}")
    if args.with_gradle_tasks:
        print(f"  Gradle tasks:     Enabled (via WFAPI)")
    if args.json_out:
        print(f"  JSON output:      {args.json_out}")
    print(f"  User-Agent:       {UA}")

    # 2) Build metadata
    info = fetch_build_info(build_url)
    if info:
        print("\nBuild metadata:")
        print(f"  Build:   {info.get('displayName')}")
        ts_ms = info.get("timestamp")
        if isinstance(ts_ms, (int, float)):
            ts = dt.datetime.fromtimestamp(ts_ms / 1000, tz=dt.timezone.utc)
            print(f"  Time:    {ts.isoformat()}")
        print(f"  Result:  {info.get('result')}")
        print(f"  URL:     {info.get('url')}")
    else:
        print("\nBuild metadata: (unavailable)")

    # JUnit
    report = fetch_test_report(build_url)
    if not report:
        raise RuntimeError(f"No test report found for build: {build_url}")

    # Correlate with Gradle tasks if requested
    suite_tasks: Dict[int, List[str]] = {}
    if args.with_gradle_tasks:
        suites = report.get("suites", [])
        # Quick pre-scan to count unique nodes
        unique_nodes = len(set(str(s.get("nodeId")) for s in suites if s.get("nodeId")))
        print(f"\nFetching WFAPI logs to correlate suites with Gradle tasks...", file=sys.stderr)
        print(f"  ({len(suites)} suites across ~{unique_nodes} unique pipeline nodes)", file=sys.stderr)
        suite_tasks = correlate_suites_with_gradle_tasks(build_url, report)
        if suite_tasks:
            print(f"✓ Successfully correlated {len(suite_tasks)} suite(s) with Gradle tasks", file=sys.stderr)
        else:
            print("⚠ No Gradle tasks found in suite logs", file=sys.stderr)

    # 3) Aggregated totals
    overall, label_totals = parse_test_report(report, args.label_index)
    print("\nAggregated totals (all pipeline labels):")
    print(f"  Suites:   {overall['suites']}")
    print(f"  Cases:    {overall['cases']}")
    print(f"  Duration: {format_duration(overall['duration'])}")
    if label_totals:
        print(f"  Labels using index {args.label_index}: {', '.join(sorted(label_totals.keys()))}")

    # 4) Per-label table
    cols = ALL_STATUSES + ["UNKNOWN"]
    header = f"\n{'Pipeline label':25} {'Duration':>12} {'Suites':>8} {'Cases':>10}" + "".join(f" {c:>10}" for c in cols)
    print(header)
    for label in sorted(label_totals.keys()):
        t = label_totals[label]
        line = f"{label:25} {format_duration(t.get('duration', 0.0)):>12} {t.get('suites', 0):8d} {t.get('cases', 0):10d}"
        for c in cols:
            line += f" {t.get(c, 0):10d}"
        print(line)

    # 5) Gradle tasks per suite (if enabled)
    if args.with_gradle_tasks and suite_tasks:
        print("\nGradle tasks by suite (from WFAPI logs):")
        suites = report.get("suites", [])
        for idx, tasks in sorted(suite_tasks.items()):
            suite = suites[idx] if idx < len(suites) else {}
            blocks = suite.get("enclosingBlockNames", []) or []
            context = " > ".join(blocks) if blocks else f"Suite {idx}"
            tasks_str = ", ".join(tasks)
            print(f"  [{idx}] {context}")
            print(f"      Tasks: {tasks_str}")

    json_path = None
    # Optional JSON
    if args.json_out:
        payload = {
            "build_url": build_url,
            "label_index": args.label_index,
            "overall": overall,
            "pipeline_labels": label_totals,
            "statuses": cols,
        }
        if args.with_gradle_tasks:
            # Add suite-to-task mapping to JSON output
            suites = report.get("suites", [])
            suite_details = []
            for idx, suite in enumerate(suites):
                detail = {
                    "index": idx,
                    "enclosingBlockNames": suite.get("enclosingBlockNames", []),
                    "nodeId": suite.get("nodeId"),
                    "duration": suite.get("duration", 0.0),
                }
                if idx in suite_tasks:
                    detail["gradle_tasks"] = suite_tasks[idx]
                suite_details.append(detail)
            payload["suite_gradle_tasks"] = suite_details

        with open(args.json_out, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)
        print(f"\nWrote JSON summary to: {args.json_out}")
        json_path = args.json_out

    return {
        "build_url": build_url,
        "pin_spec": pin_spec,
        "overall": overall,
        "labels": label_totals,
        "suite_tasks": suite_tasks,
        "json_path": json_path,
        "report": report,
    }


def main() -> None:
    args = parse_args()
    try:
        run(args)
    except Exception as exc:  # pylint: disable=broad-except
        print(f"ERROR: summary failed: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
