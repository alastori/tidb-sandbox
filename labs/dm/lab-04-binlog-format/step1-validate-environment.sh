#!/bin/bash
# Step 1: Validate Environment Startup
# Usage: ./step1-validate-environment.sh

set -e

ts=$(cat /tmp/lab04_ts.txt 2>/dev/null || date -u +%Y%m%dT%H%M%SZ)
echo $ts > /tmp/lab04_ts.txt

{
  echo "# Environment startup validation - $ts"
  echo ""
  echo "# Docker container status:"
  docker compose ps
  echo ""
  echo "# TiDB version:"
  docker exec -i lab04-mysql mysql -h tidb -P 4000 -u root -e "SELECT VERSION();" 2>&1 | grep -v Warning
  echo ""
  echo "# MySQL version and binlog format:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -e "SELECT VERSION(); SHOW VARIABLES LIKE 'binlog_format'; SHOW VARIABLES LIKE 'binlog_row_image';" 2>&1 | grep -v Warning
} | tee results/step1-environment-startup-$ts.log

echo ""
echo "✓ Step 1 validation complete. Results saved to: results/step1-environment-startup-$ts.log"