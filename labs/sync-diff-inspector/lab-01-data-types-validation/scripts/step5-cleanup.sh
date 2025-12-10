#!/bin/bash
set -e

echo "=== Cleaning up containers ==="

docker rm -f mysql8sd tidbsd 2>/dev/null || true

echo "=== Cleanup completed ==="
