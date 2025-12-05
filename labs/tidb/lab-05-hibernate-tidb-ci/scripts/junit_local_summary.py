#!/usr/bin/env python3
"""
Summarize Hibernate JUnit XML results that were collected by junit_local_collect.py.

The goal is to mirror the terminology and layout used by
`junit_pipeline_label_summary.py` so we can diff local runs against the Jenkins
pipeline output.

Usage examples:
  ./junit_local_summary.py --root tmp/mysql-results-20251103-143022
  ./junit_local_summary.py --root tmp/mysql-results-20251103-143022 --json-out tmp/mysql-summary
"""

import argparse
import datetime as dt
import json
import os
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, Optional, Tuple
from xml.etree import ElementTree

from env_utils import load_lab_env, require_path


def friendly_duration(seconds: float) -> str:
    """Format seconds into the same h/m/s style used in the pipeline summary."""
    if seconds <= 0:
        return "0s"
    total = int(round(seconds))
    hours, rem = divmod(total, 3600)
    minutes, secs = divmod(rem, 60)
    chunks = []
    if hours:
        chunks.append(f"{hours}h")
    if minutes:
        chunks.append(f"{minutes}m")
    if secs or not chunks:
        chunks.append(f"{secs}s")
    return " ".join(chunks)


def find_test_suites(root: Path) -> Iterable[Tuple[Path, ElementTree.Element]]:
    """Yield (path, testsuite_element) for every JUnit XML file under root."""
    pattern = "**/test-results/**/*.xml"
    for xml_path in root.glob(pattern):
        try:
            tree = ElementTree.parse(xml_path)
        except ElementTree.ParseError:
            continue
        suite = tree.getroot()
        if suite.tag == "testsuite":
            yield xml_path, suite


def module_name_for(path: Path, root: Path) -> str:
    """
    Derive a module identifier from an XML path.

    We take the first path segment leading up to 'target/' so that
    'hibernate-core/target/test-results/test/...' becomes 'hibernate-core'.
    """
    rel = path.relative_to(root)
    parts = rel.parts
    try:
        idx = parts.index("target")
    except ValueError:
        idx = 1 if len(parts) else 0
    module = parts[idx - 1] if idx > 0 else parts[0] if parts else "unknown"
    return module


def extract_db_hint(env_lines: Iterable[str]) -> str:
    """Return the value of an `RDBMS=` line if present."""
    for line in env_lines:
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key == "RDBMS":
            value = value.strip()
            if value:
                return value
    return "unknown"


def tail_log_for_env(log_path: Path, limit: int = 256) -> str:
    """Tail a log file looking for an `RDBMS=` printout."""
    try:
        text = log_path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return "unknown"
    lines = text.splitlines()[-limit:]
    return extract_db_hint(reversed(lines))


SCRIPT_DIR = Path(__file__).resolve().parent
LAB_ENV = load_lab_env(required=("LOG_DIR",))
DEFAULT_LOG_DIR = require_path("LOG_DIR", must_exist=False, create=True)


def infer_from_filename(log_path: Path) -> str:
    """
    Infer the DB name from the log filename if possible.

    Examples:
      tmp/mysql-ci-balanced-YYYY.log -> mysql_8_0
      tmp/tidb-ci-full-YYYY.log      -> tidb
    """
    name = log_path.name.lower()
    if name.startswith("mysql-ci"):
        return "mysql_8_0"
    if name.startswith("tidb-ci"):
        return "tidb"
    return "unknown"


def guess_log_path(log_dir: Path = DEFAULT_LOG_DIR) -> Optional[Path]:
    """
    Attempt to locate the most recent mysql-ci log under the configured log directory.

    We look for files matching mysql-ci-*.log (including balanced/headroom variants)
    and return the newest one. Returns None if nothing matches.
    """
    if not log_dir.exists():
        return None
    candidates = []
    for pattern in ("mysql-ci-*.log", "tidb-ci-*.log"):
        candidates.extend(log_dir.glob(pattern))
    if not candidates:
        return None
    newest = max(candidates, key=lambda p: p.stat().st_mtime, default=None)
    return newest


def load_manifest(path: Path) -> Optional[dict]:
    """Load a collection manifest if it exists."""
    if not path.exists():
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"WARNING: Failed to read manifest {path}: {exc}", file=sys.stderr)
        return None


def discover_log_in_collection(root: Path) -> Optional[Path]:
    """Return the newest log file under root/logs if present."""
    logs_dir = root / "logs"
    if not logs_dir.is_dir():
        return None
    candidates = list(logs_dir.glob("*.log"))
    if not candidates:
        candidates = list(logs_dir.glob("**/*.log"))
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime)


def resolve_log_path(log_arg: Optional[str], root: Path, manifest: Optional[dict]) -> Optional[Path]:
    """Resolve the log file path from CLI input, manifest, or discovery."""
    if log_arg:
        candidate = Path(log_arg)
        if not candidate.is_absolute():
            relative = (root / log_arg).resolve()
            if relative.exists():
                candidate = relative
            else:
                log_dir_candidate = (DEFAULT_LOG_DIR / log_arg).resolve()
                if log_dir_candidate.exists():
                    candidate = log_dir_candidate
                else:
                    candidate = (SCRIPT_DIR / log_arg).resolve()
        return candidate

    if manifest:
        log_copy = manifest.get("log_copy")
        if log_copy:
            candidate = Path(log_copy)
            if not candidate.is_absolute():
                candidate = (root / log_copy).resolve()
            return candidate

    collected = discover_log_in_collection(root)
    if collected:
        return collected

    return guess_log_path()


def aggregate(root: Path) -> Tuple[dict, Dict[str, dict]]:
    overall = {
        "files": 0,
        "tests": 0,
        "failures": 0,
        "errors": 0,
        "skipped": 0,
        "time": 0.0,
    }
    per_module: Dict[str, dict] = defaultdict(lambda: {
        "tests": 0,
        "failures": 0,
        "errors": 0,
        "skipped": 0,
        "time": 0.0,
        "files": 0,
    })

    for xml_path, suite in find_test_suites(root):
        overall["files"] += 1
        module = module_name_for(xml_path, root)
        bucket = per_module[module]
        bucket["files"] += 1

        tests = int(suite.attrib.get("tests", 0))
        failures = int(suite.attrib.get("failures", 0))
        errors = int(suite.attrib.get("errors", 0))
        skipped = int(suite.attrib.get("skipped", 0))
        time = float(suite.attrib.get("time", 0.0))

        for key, value in (
            ("tests", tests),
            ("failures", failures),
            ("errors", errors),
            ("skipped", skipped),
        ):
            overall[key] += value
            bucket[key] += value

        overall["time"] += time
        bucket["time"] += time

    return overall, per_module


def print_report(root: Path, overall: dict, per_module: Dict[str, dict], db_hint: str, log_hint: str) -> None:
    print("Starting local JUnit summary…")
    print(f"  Root path:        {root}")
    print(f"  XML files found:  {overall['files']}")
    print(f"  Database:         {db_hint}")
    if log_hint:
        print(f"                 ({log_hint})")

    print("\nAggregated totals (all modules):")
    print(f"  Tests:    {overall['tests']}")
    print(f"  Failures: {overall['failures']}")
    print(f"  Errors:   {overall['errors']}")
    print(f"  Skipped:  {overall['skipped']}")
    print(f"  Duration: {friendly_duration(overall['time'])}")

    if not per_module:
        print("\nNo JUnit XML files discovered under the given root.")
        return

    header = (
        f"\n{'Module':25} {'Duration':>12} {'Files':>8} {'Tests':>10} "
        f"{'Failures':>10} {'Errors':>10} {'Skipped':>10}"
    )
    print(header)
    for module in sorted(per_module.keys()):
        stats = per_module[module]
        line = (
            f"{module:25} {friendly_duration(stats['time']):>12} "
            f"{stats['files']:8d} {stats['tests']:10d} "
            f"{stats['failures']:10d} {stats['errors']:10d} {stats['skipped']:10d}"
        )
        print(line)


def parse_args(argv: Optional[Iterable[str]] = None) -> argparse.Namespace:
    """Parse CLI arguments."""
    ap = argparse.ArgumentParser(
        description="Summarize local JUnit XML results (target/test-results)."
    )
    ap.add_argument(
        "--root",
        default=".",
        help="Directory to scan (default: current directory)",
    )
    ap.add_argument(
        "--json-out",
        help="Optional path to write a JSON payload matching the console output",
    )
    ap.add_argument(
        "--log",
        default=None,
        help="Path to a build log (for inferring RDBMS from ENV prints). "
             "Defaults to the collected log or newest mysql-ci log under LOG_DIR.",
    )
    ap.add_argument(
        "--manifest",
        help="Path to collection manifest JSON (default: ROOT/collection.json if present).",
    )
    ap.add_argument(
        "--timestamp",
        help="Override timestamp used for archive/JSON naming (format: YYYYMMDD-HHMMSS)",
    )
    return ap.parse_args(argv)


def run(args: argparse.Namespace) -> dict:
    """
    Execute the summary workflow using an argparse namespace.

    Returns a dictionary containing the computed summary metadata.
    """
    root = Path(args.root).resolve()
    if not root.exists():
        raise FileNotFoundError(f"root path not found: {root}")

    if args.manifest:
        manifest_path = Path(args.manifest)
        if not manifest_path.is_absolute():
            manifest_path = (SCRIPT_DIR / manifest_path).resolve()
    else:
        manifest_path = (root / "collection.json").resolve()

    manifest_ref = manifest_path if manifest_path.exists() else None
    manifest = load_manifest(manifest_path)

    timestamp = args.timestamp
    if not timestamp and manifest:
        timestamp = manifest.get("timestamp")
    if not timestamp:
        timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")

    overall, per_module = aggregate(root)
    log_path = resolve_log_path(args.log, root, manifest)

    db_hint = "unknown"
    log_hint = ""
    if log_path:
        if log_path.exists():
            inferred = tail_log_for_env(log_path)
            if inferred == "unknown":
                inferred = infer_from_filename(log_path)
            if inferred != "unknown":
                db_hint = inferred
            try:
                rel = log_path.relative_to(root)
                log_hint = f"log: {rel}"
            except ValueError:
                log_hint = f"log: {log_path}"
        else:
            log_hint = f"log: {log_path} (missing)"
    else:
        log_hint = "log: auto-detect failed"

    print_report(root, overall, per_module, db_hint, log_hint)

    json_path: Optional[Path] = None
    if args.json_out:
        json_path = Path(args.json_out).resolve()
        if not json_path.name.endswith(".json"):
            json_path = json_path.parent / f"{json_path.name}-{timestamp}.json"

        payload = {
            "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "timestamp": timestamp,
            "root": str(root),
            "manifest": str(manifest_ref) if manifest_ref else None,
            "database": db_hint,
            "overall": overall,
            "modules": per_module,
        }
        if log_path:
            payload["log"] = str(log_path)

        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)
        print(f"\nWrote JSON summary to: {json_path}")

    return {
        "root": root,
        "manifest_path": manifest_path,
        "manifest": manifest,
        "manifest_ref": manifest_ref,
        "overall": overall,
        "per_module": per_module,
        "log_path": log_path,
        "db_hint": db_hint,
        "timestamp": timestamp,
        "json_path": str(json_path) if json_path else None,
    }


def main() -> None:
    args = parse_args()
    try:
        run(args)
    except FileNotFoundError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:  # pylint: disable=broad-except
        print(f"ERROR: summary failed: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
