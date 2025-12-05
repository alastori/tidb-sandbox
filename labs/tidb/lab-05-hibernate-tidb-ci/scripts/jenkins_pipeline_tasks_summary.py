#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Summarize Jenkins Pipeline (WFAPI) logs to list executed Gradle :*:test tasks.

What it does
------------
- Pins a job URL to a concrete build (:lastBuild, :lastSuccessfulBuild, or a number).
- Walks the Pipeline "Test" stage (configurable) via WFAPI.
- Fetches step logs (node logs) and scans for Gradle task execution lines:
    > Task :hibernate-core:test
- Counts occurrences, and flags "UP-TO-DATE" / "SKIPPED" markers near those tasks.
- Reconstructs a best-effort Pipeline context path (Stage → Parallel branch → ...).
- Prints a compact table and (optionally) writes a JSON manifest.

Usage
-----
    jenkins_pipeline_tasks_summary.py https://ci.hibernate.org/job/hibernate-orm-nightly/job/main --last-success
    jenkins_pipeline_tasks_summary.py <job-or-build-url> [--last | --last-success | --build N]
                                      [--stage-name Test] [--label-filter mysql_8_0]
                                      [--modules-per-label] [--json-out scope_tasks.json] [-v]
"""

import argparse
import collections
import datetime as _dt
import json
import re
import sys
import time
import urllib.error
import urllib.request
from typing import Dict, List, Tuple, Optional, Set

UA = "jenkins-pipeline-tasks-summary/1.0"
TIMEOUT = 30
VERBOSE = False
FILTER_LABEL = None
MODULES_PER_LABEL = False

# Match both plain text and HTML-encoded task lines
# Plain: "> Task :module:test"
# HTML: "&gt;<b class="gradle-task"> Task :module:test</b>"
TASK_RE      = re.compile(r'^(?:&gt;|>)(?:<b[^>]*>)?\s*Task\s+(:[A-Za-z0-9_-]+(?::[A-Za-z0-9_-]+)*:test)\b')
UPTODATE_RE  = re.compile(r'UP-TO-DATE')
SKIPPED_RE   = re.compile(r'\bSKIPPED\b')

# Extract database from Gradle command line
# Matches: -Pdb=mysql_ci, -Pdb=pgsql_ci, -Pdb=tidb, etc.
DB_PARAM_RE  = re.compile(r'-Pdb=([a-z0-9_]+)')
# Also match RDBMS export if present
RDBMS_RE     = re.compile(r'(?:export\s+)?RDBMS=([a-z0-9_]+)', re.IGNORECASE)

# -------- HTTP helpers --------

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
        # Re-raise other HTTP errors
        raise
    except Exception as e:
        if VERBOSE:
            print(f"  [ERROR] {url}: {e}", file=sys.stderr)
        return None

# -------- Build URL pinning (same style as your other script) --------

def normalize_job_or_build_url(url: str) -> str:
    u = url.rstrip("/")
    parts = u.split("/")
    if parts and parts[-1].isdigit():
        return u
    return u

def pin_build(url: str, build_spec: str) -> str:
    u = normalize_job_or_build_url(url)
    if u.split("/")[-1].isdigit():
        return u
    if build_spec.isdigit():
        return u + "/" + build_spec
    return u + "/" + build_spec  # lastBuild / lastSuccessfulBuild

# -------- WFAPI helpers --------
# Blue Ocean WFAPI endpoints we use:
#   <BUILD>/wfapi/describe
#   <BUILD>/execution/node/<id>/wfapi/children
#   <BUILD>/execution/node/<id>/wfapi/log
#   <BUILD>/execution/node/<id>           (fallback to get displayName)

def wfapi_describe(build_url: str) -> Optional[dict]:
    return http_get_json(build_url.rstrip("/") + "/wfapi/describe")

def wfapi_describe_node(build_url: str, node_id: str) -> Optional[dict]:
    """
    Get detailed description of a node, including its child nodes in stageFlowNodes.
    """
    url = build_url.rstrip("/") + f"/execution/node/{node_id}/wfapi/describe"
    if VERBOSE:
        print(f"  Fetching node description: {url}", file=sys.stderr)
    return http_get_json(url, ignore_404=True)

def wfapi_children(build_url: str, node_id: str) -> List[dict]:
    """
    Get children of a node from its stageFlowNodes. Returns empty list if not found.
    """
    desc = wfapi_describe_node(build_url, node_id)
    if not desc:
        return []
    # Children are in the stageFlowNodes array
    return desc.get("stageFlowNodes", [])

def wfapi_log_lines(build_url: str, node_id: str) -> List[str]:
    """
    Get log lines for a node. Returns empty list if endpoint fails.
    Uses the console log endpoint to get complete logs (WFAPI log is truncated).
    """
    # Use console log endpoint which returns full text, not truncated like wfapi/log
    url = build_url.rstrip("/") + f"/execution/node/{node_id}/log"
    if VERBOSE:
        print(f"  Fetching logs: {url}", file=sys.stderr)
    
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

def node_display_name(build_url: str, node_id: str) -> str:
    """
    Get display name for a node. Returns node_id if lookup fails.
    """
    desc = wfapi_describe_node(build_url, node_id)
    if isinstance(desc, dict):
        # Prefer parameterDescription (for parameterized steps), then name, fallback to id
        return desc.get("parameterDescription") or desc.get("name") or str(node_id)
    return str(node_id)

# -------- Graph traversal --------

def find_stage_ids(build_url: str, stage_name: str) -> List[str]:
    """
    Returns WFAPI node ids for stages whose name matches `stage_name`.
    """
    d = wfapi_describe(build_url)
    if not d:
        return []
    stages = d.get("stages") or []
    ids = []
    for st in stages:
        name = st.get("name") or ""
        if name == stage_name:
            sid = st.get("id")
            if sid is not None:
                ids.append(str(sid))
    return ids

def walk_descendants(build_url: str, root_id: str, max_depth: int = 3) -> List[Tuple[str, List[str]]]:
    """
    DFS walk from a stage root (root_id), up to max_depth levels,
    returning (node_id, context_path[]) for each node that has logs.

    context_path is a list of display names: [Stage, Branch, ... , Node]
    """
    results: List[Tuple[str, List[str]]] = []

    def _walk(node_id: str, path: List[str], depth: int):
        # Get children
        kids = wfapi_children(build_url, node_id)
        if not kids:
            # Leaf (or unknown); still record this node
            results.append((node_id, path))
            return

        for kid in kids:
            cid = str(kid.get("id"))
            # fetch a name for context path
            try:
                nm = node_display_name(build_url, cid)
            except Exception:
                nm = cid

            new_path = path + [nm]
            if depth < max_depth:
                _walk(cid, new_path, depth + 1)
            else:
                results.append((cid, new_path))

    # Seed path with root stage display name
    root_name = node_display_name(build_url, root_id)
    _walk(root_id, [root_name], 0)
    return results

# -------- Log parsing & aggregation --------

class TaskCounters:
    __slots__ = ("seen", "up_to_date", "skipped")

    def __init__(self):
        self.seen = 0
        self.up_to_date = 0
        self.skipped = 0

    def to_dict(self) -> Dict[str, int]:
        return {
            "seen": self.seen,
            "up_to_date": self.up_to_date,
            "skipped": self.skipped,
        }

def extract_database_from_logs(lines: List[str]) -> Optional[str]:
    """
    Extract the database being tested from the logs.
    Looks for -Pdb= parameter or RDBMS= export.
    """
    for ln in lines:
        # Try -Pdb= parameter first
        m = DB_PARAM_RE.search(ln)
        if m:
            return m.group(1)
        # Try RDBMS= export
        m = RDBMS_RE.search(ln)
        if m:
            return m.group(1)
    return None


def derive_label_from_context(context_path: List[str]) -> Optional[str]:
    """
    Given the context path [Stage, Parallel branch, ...], return the label
    (first branch under the stage). Returns None if not available.
    """
    if len(context_path) >= 2:
        return context_path[1]
    return None

def scan_logs_for_tasks(lines: List[str]) -> Tuple[Optional[str], List[Tuple[str, int, int]]]:
    """
    From a list of log lines, return database and list of task triples:
      (database, [(task_path, uptodate_hits, skipped_hits), ...])
    """
    # Extract database first
    database = extract_database_from_logs(lines)
    
    out: List[Tuple[str, int, int]] = []
    current_task: Optional[str] = None
    uptodate_hits = 0
    skipped_hits = 0

    for ln in lines:
        m = TASK_RE.match(ln)
        if m:
            # If we were tracking a previous task, flush it
            if current_task is not None:
                out.append((current_task, uptodate_hits, skipped_hits))
            # Start a new task scope
            current_task = m.group(1)
            uptodate_hits = 0
            skipped_hits = 0
            continue

        # Only count markers in the immediate vicinity of a task
        if current_task is not None:
            if UPTODATE_RE.search(ln):
                uptodate_hits += 1
            elif SKIPPED_RE.match(ln):
                skipped_hits += 1

    # Flush tail
    if current_task is not None:
        out.append((current_task, uptodate_hits, skipped_hits))

    return (database, out)

# -------- Pretty printing --------

def print_table(global_counts: Dict[str, TaskCounters],
                context_counts: Dict[str, Dict[str, TaskCounters]],
                build_url: str,
                modules_per_label: Optional[Dict[str, Set[str]]] = None):
    print(f"Source build: {build_url}")
    print("\nOverall tasks observed:")
    print(f"{'task':45} {'seen':>6} {'up_to_date':>10} {'skipped':>8}")
    for task in sorted(global_counts.keys()):
        c = global_counts[task]
        print(f"{task:45} {c.seen:6d} {c.up_to_date:10d} {c.skipped:8d}")

    print("\nBy pipeline context (path) and task:")
    print(f"{'context':50} {'task':40} {'seen':>6} {'up_to_date':>10} {'skipped':>8}")
    for ctx in sorted(context_counts.keys()):
        row = context_counts[ctx]
        for task in sorted(row.keys()):
            c = row[task]
            print(f"{ctx:50} {task:40} {c.seen:6d} {c.up_to_date:10d} {c.skipped:8d}")

    if modules_per_label:
        print("\nModules observed per label:")
        for label in sorted(modules_per_label.keys()):
            modules = sorted(modules_per_label[label])
            modules_str = ", ".join(modules) if modules else "(none)"
            print(f"  {label}: {modules_str}")

# -------- Main --------

def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    """Parse CLI arguments."""
    ap = argparse.ArgumentParser(
        description="Summarize executed Gradle :*:test tasks from Jenkins Pipeline logs (WFAPI)."
    )
    ap.add_argument(
        "url",
        help="Job or build URL, e.g. https://ci.hibernate.org/job/hibernate-orm-nightly/job/main",
    )
    sel = ap.add_mutually_exclusive_group()
    sel.add_argument("--last", action="store_true", help="Use lastBuild (default if job URL provided)")
    sel.add_argument("--last-success", action="store_true", help="Use lastSuccessfulBuild")
    ap.add_argument("--build", metavar="N", help="Pin to build number N")
    ap.add_argument("--stage-name", default="Test", help="Top-level stage to scan (default: Test)")
    ap.add_argument("--max-depth", type=int, default=3, help="Descend this many child levels (default: 3)")
    ap.add_argument("--json-out", help="Write JSON manifest to this path")
    ap.add_argument(
        "--label-filter",
        help="Only include contexts whose label (first branch under the stage) matches this string",
    )
    ap.add_argument("--modules-per-label", action="store_true", help="Also list unique Gradle modules observed per label")
    ap.add_argument("--verbose", "-v", action="store_true", help="Enable verbose output for debugging")
    return ap.parse_args(argv)


def run(args: argparse.Namespace) -> dict:
    """
    Execute the Jenkins pipeline tasks summary workflow using parsed args.

    Returns a dictionary describing the collected summary, manifest, and build metadata.
    """
    global VERBOSE
    global FILTER_LABEL
    global MODULES_PER_LABEL

    prev_verbose = VERBOSE
    prev_filter = FILTER_LABEL
    prev_modules = MODULES_PER_LABEL

    try:
        VERBOSE = args.verbose
        FILTER_LABEL = args.label_filter.lower() if args.label_filter else None
        MODULES_PER_LABEL = args.modules_per_label

        base = normalize_job_or_build_url(args.url)
        if base.split("/")[-1].isdigit():
            build_url = base
            pin_spec = "(pinned build)"
        else:
            spec = "lastBuild"
            if args.last_success:
                spec = "lastSuccessfulBuild"
            if args.build:
                spec = args.build
            build_url = pin_build(base, spec)
            pin_spec = spec

        print(f"Retrieving Pipeline graph from: {build_url}", file=sys.stderr)

        try:
            stage_ids = find_stage_ids(build_url, args.stage_name)
        except urllib.error.HTTPError as e:
            raise RuntimeError(
                f"Failed to retrieve pipeline description: HTTP {e.code} {e.reason} ({e.url})"
            ) from e
        except Exception as exc:
            raise RuntimeError(f"Failed to retrieve pipeline description: {exc}") from exc

        if not stage_ids:
            raise RuntimeError(f"No stage named '{args.stage_name}' found via WFAPI.")

        if VERBOSE:
            print(f"Found {len(stage_ids)} stage(s) matching '{args.stage_name}': {stage_ids}", file=sys.stderr)

        global_counts: Dict[str, TaskCounters] = collections.defaultdict(TaskCounters)
        context_counts: Dict[str, Dict[str, TaskCounters]] = collections.defaultdict(
            lambda: collections.defaultdict(TaskCounters)
        )
        manifest_tasks: List[dict] = []
        modules_per_label_map: Dict[str, Set[str]] = collections.defaultdict(set)

        for sid in stage_ids:
            if VERBOSE:
                print(f"\nProcessing stage ID: {sid}", file=sys.stderr)

            try:
                descendants = walk_descendants(build_url, sid, max_depth=args.max_depth)
            except Exception as exc:
                print(f"WARNING: Failed to walk descendants for stage {sid}: {exc}", file=sys.stderr)
                continue

            if VERBOSE:
                print(f"Found {len(descendants)} descendant nodes", file=sys.stderr)

            for node_id, ctx_path in descendants:
                label = derive_label_from_context(ctx_path)
                try:
                    lines = wfapi_log_lines(build_url, node_id)
                except Exception as exc:
                    if VERBOSE:
                        print(f"WARNING: Failed to get logs for node {node_id}: {exc}", file=sys.stderr)
                    continue

                if not lines:
                    continue

                database, hits = scan_logs_for_tasks(lines)
                if not hits:
                    continue

                effective_label = database or label
                normalized_label = effective_label.lower() if effective_label else None
                if FILTER_LABEL and (normalized_label is None or normalized_label != FILTER_LABEL):
                    if VERBOSE:
                        print(
                            f"  Skipping node {node_id} (db/label '{normalized_label}' != filter '{FILTER_LABEL}')",
                            file=sys.stderr,
                        )
                    continue

                if database:
                    ctx_str = f"{' > '.join(ctx_path)} [db:{database}]"
                else:
                    ctx_str = " > ".join(ctx_path)

                if VERBOSE:
                    db_info = f" (db: {database})" if database else ""
                    label_info = f" [label:{label}]" if label else ""
                    print(f"  Found {len(hits)} task(s) in: {ctx_str}{db_info}{label_info}", file=sys.stderr)

                for task, upt, sk in hits:
                    gc = global_counts[task]
                    gc.seen += 1
                    gc.up_to_date += upt
                    gc.skipped += sk

                    cc = context_counts[ctx_str][task]
                    cc.seen += 1
                    cc.up_to_date += upt
                    cc.skipped += sk

                    modules_key = effective_label or label
                    if MODULES_PER_LABEL and modules_key:
                        parts = [p for p in task.split(":") if p]
                        if parts:
                            modules_per_label_map[modules_key].add(parts[0])

                    manifest_tasks.append(
                        {
                            "task": task,
                            "context": ctx_path,
                            "database": database,
                            "node_id": node_id,
                            "label": effective_label or label,
                            "up_to_date_hits": upt,
                            "skipped_hits": sk,
                        }
                    )

        modules_section = modules_per_label_map if MODULES_PER_LABEL else None
        print_table(global_counts, context_counts, build_url, modules_section)

        summary = {
            "overall": {t: c.to_dict() for t, c in global_counts.items()},
            "by_context": {
                ctx: {t: c.to_dict() for t, c in row.items()}
                for ctx, row in context_counts.items()
            },
            "modules_per_label": {
                label: sorted(list(mods))
                for label, mods in (modules_section or {}).items()
            }
            if modules_section
            else None,
        }

        json_path = None
        if args.json_out:
            out = {
                "build_url": build_url,
                "collected_at": _dt.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
                "stage_name": args.stage_name,
                "label_filter": FILTER_LABEL,
                "max_depth": args.max_depth,
                "tasks": manifest_tasks,
                "summary": summary,
            }
            with open(args.json_out, "w", encoding="utf-8") as f:
                json.dump(out, f, indent=2)
            print(f"\nWrote JSON manifest to: {args.json_out}")
            json_path = args.json_out

        return {
            "build_url": build_url,
            "pin_spec": pin_spec,
            "stage_ids": stage_ids,
            "summary": summary,
            "manifest_tasks": manifest_tasks,
            "json_path": json_path,
        }
    finally:
        VERBOSE = prev_verbose
        FILTER_LABEL = prev_filter
        MODULES_PER_LABEL = prev_modules


def main() -> None:
    args = parse_args()
    try:
        run(args)
    except Exception as exc:  # pylint: disable=broad-except
        print(f"ERROR: task summary failed: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
