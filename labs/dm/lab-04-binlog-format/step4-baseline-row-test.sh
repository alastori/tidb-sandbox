#!/bin/bash
# Step 4: Baseline Test with ROW Format
# Usage: ./step4-baseline-row-test.sh

set -e

ts=$(cat /tmp/lab04_ts.txt)

{
  echo "# Baseline test with binlog_format=ROW - $ts"

  echo ""
  echo "# Confirming binlog format:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -e "SHOW VARIABLES LIKE 'binlog_format';" 2>&1 | grep -v Warning

  echo ""
  echo "# Executing multi-statement batch (trigger_error.py):"
  docker exec lab04-mysql python3 /tmp/trigger_error.py

  echo ""
  echo "# Waiting 5 seconds for replication..."
  sleep 5

  echo ""
  echo "# DM task status after baseline:"
  docker exec lab04-tidb sh -c 'tiup dmctl --master-addr "$(hostname -i):8261" query-status lab04-task' 2>&1 | grep -E '"stage"|"synced"' | head -5

  echo ""
  echo "# Source (MySQL) row count:"
  docker exec -i lab04-mysql mysql -uroot -pPass_1234 -D test_db -e "SELECT COUNT(*) AS source_count FROM broken_table;" 2>&1 | grep -v Warning

  echo ""
  echo "# Target (TiDB) row count:"
  docker exec -i lab04-mysql mysql -h tidb -P 4000 -u root -D test_db -e "SELECT COUNT(*) AS target_count FROM broken_table;" 2>&1 | grep -v Warning

  echo ""
  echo "# Target (TiDB) data sample:"
  docker exec -i lab04-mysql mysql -h tidb -P 4000 -u root -D test_db -e "SELECT * FROM broken_table LIMIT 5;" 2>&1 | grep -v Warning
} | tee results/step4-baseline-row-format-$ts.log

echo ""
echo "✓ Step 4 complete. Results saved to: results/step4-baseline-row-format-$ts.log"