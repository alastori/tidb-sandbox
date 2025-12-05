#!/bin/bash
# Step 3: Register Source and Start DM Task
# Usage: ./step3-start-dm-task.sh

set -e

ts=$(cat /tmp/lab04_ts.txt)

# Copy configuration files
docker cp source.yaml lab04-tidb:/tmp/source.yaml
docker cp task.yaml   lab04-tidb:/tmp/task.yaml

{
  echo "# Registering DM source - $ts"
  docker exec lab04-tidb sh -c 'tiup dmctl --master-addr "$(hostname -i):8261" operate-source create /tmp/source.yaml' 2>&1 | grep -A 20 "result"

  echo ""
  echo "# Starting DM task (precheck will validate binlog_format=ROW):"
  docker exec lab04-tidb sh -c 'tiup dmctl --master-addr "$(hostname -i):8261" start-task /tmp/task.yaml' 2>&1 | grep -A 20 "result"

  echo ""
  echo "# Initial task status:"
  docker exec lab04-tidb sh -c 'tiup dmctl --master-addr "$(hostname -i):8261" query-status lab04-task' 2>&1 | grep -A 50 "result"
} | tee results/step3-dm-task-start-$ts.json

echo ""
echo "✓ Step 3 complete. Results saved to: results/step3-dm-task-start-$ts.json"