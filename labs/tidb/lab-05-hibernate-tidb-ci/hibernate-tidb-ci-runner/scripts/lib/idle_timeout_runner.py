#!/usr/bin/env python3
"""
Execute a command while watching its stdout/stderr streams. If the command
stops producing output for longer than the configured idle timeout, the
process is terminated and exit code 124 is returned (matching GNU timeout).

The script mirrors all output to the parent stdout/stderr and appends it to
the specified log file so CI jobs can surface partial logs when a timeout
occurs.
"""

import argparse
import os
import subprocess
import sys
import threading
import time


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a command with an idle timeout watchdog."
    )
    parser.add_argument(
        "--timeout",
        type=int,
        required=True,
        help="Maximum idle seconds allowed between log lines.",
    )
    parser.add_argument(
        "--log-file",
        required=True,
        help="File path to append the combined stdout/stderr stream.",
    )
    parser.add_argument(
        "cmd",
        nargs=argparse.REMAINDER,
        help="Command to execute (prefix with -- to separate).",
    )
    args = parser.parse_args()
    if not args.cmd:
        parser.error("No command supplied. Use: ... -- <command> [args]")
    if args.cmd[0] == "--":
        args.cmd = args.cmd[1:]
    return args


def main() -> int:
    args = parse_args()
    log_path = os.path.abspath(args.log_file)
    os.makedirs(os.path.dirname(log_path), exist_ok=True)

    last_output = time.monotonic()
    log_file = open(log_path, "a", encoding="utf-8", buffering=1)

    proc = subprocess.Popen(
        args.cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    heartbeat_env = os.environ.get("IDLE_WATCHDOG_HEARTBEAT", "")
    try:
        heartbeat_interval = int(heartbeat_env) if heartbeat_env else 60
    except ValueError:
        heartbeat_interval = 60
    if heartbeat_interval <= 0 or heartbeat_interval >= args.timeout:
        heartbeat_interval = min(60, max(args.timeout // 2, 10)) if args.timeout > 1 else 1

    last_heartbeat = time.monotonic()

    def reader() -> None:
        nonlocal last_output
        try:
            assert proc.stdout is not None
            for line in proc.stdout:
                last_output = time.monotonic()
                sys.stdout.write(line)
                sys.stdout.flush()
                log_file.write(line)
                log_file.flush()
        finally:
            log_file.flush()

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()

    exit_code = 0
    try:
        while True:
            now = time.monotonic()
            ret = proc.poll()
            if ret is not None:
                exit_code = ret
                break
            if now - last_output > args.timeout:
                proc.kill()
                exit_code = 124
                sys.stderr.write(
                    f"\nERROR: Command idle for more than {args.timeout}s. Terminated.\n"
                )
                sys.stderr.flush()
                break
            if now - last_output >= heartbeat_interval and now - last_heartbeat >= heartbeat_interval:
                idle_for = int(now - last_output)
                message = f"[idle-watchdog] Waiting {idle_for}s without output (timeout {args.timeout}s).\n"
                sys.stderr.write(message)
                sys.stderr.flush()
                log_file.write(message)
                log_file.flush()
                last_heartbeat = now
            time.sleep(1)
    finally:
        thread.join(timeout=5)
        log_file.close()

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
