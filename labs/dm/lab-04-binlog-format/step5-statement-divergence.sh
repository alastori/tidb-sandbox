#!/bin/bash
# Step 5: STATEMENT Format Experiment - Silent Divergence
# Usage: ./step5-statement-divergence.sh

set -e

ts=$(cat /tmp/lab04_ts.txt)

{
  echo "# Switching to STATEMENT format - $ts"

  echo ""
  echo "# Changing binlog_format globally and for session:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -e "SET GLOBAL binlog_format='STATEMENT'; SET SESSION binlog_format='STATEMENT'; FLUSH LOGS; SHOW VARIABLES LIKE 'binlog_format';" 2>&1 | grep -v Warning

  echo ""
  echo "# Truncating table to reset baseline:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -D test_db -e "TRUNCATE TABLE broken_table;" 2>&1 | grep -v Warning || echo "(truncated)"
  docker exec -i lab04-mysql mysql -h tidb -P 4000 -u root -D test_db -e "TRUNCATE TABLE broken_table;" 2>&1 | grep -v Warning || echo "(truncated)"

  echo ""
  echo "# Executing multi-statement batch with STATEMENT format:"
  docker exec lab04-mysql python3 /tmp/trigger_error.py

  echo ""
  echo "# Waiting 5 seconds for replication..."
  sleep 5

  echo ""
  echo "# DM task status:"
  docker exec lab04-tidb sh -c 'tiup dmctl --master-addr "$(hostname -i):8261" query-status lab04-task' 2>&1 | grep -E '"stage"|"synced"' | head -5

  echo ""
  echo "# Source (MySQL) row count:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -D test_db -e "SELECT COUNT(*) AS source_count FROM broken_table;" 2>&1 | grep -v Warning

  echo ""
  echo "# Target (TiDB) row count:"
  docker exec -i lab04-mysql mysql -h tidb -P 4000 -u root -D test_db -e "SELECT COUNT(*) AS target_count FROM broken_table;" 2>&1 | grep -v Warning
} | tee results/step5-statement-format-divergence-$ts.log

echo ""
echo "✓ Step 5 complete. Results saved to: results/step5-statement-format-divergence-$ts.log"