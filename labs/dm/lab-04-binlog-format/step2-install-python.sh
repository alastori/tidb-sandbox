#!/bin/bash
# Step 2: Install Python Client Libraries
# Usage: ./step2-install-python.sh

set -e

ts=$(cat /tmp/lab04_ts.txt)

{
  echo "# Installing Python and MySQL connector - $ts"
  docker exec lab04-mysql microdnf install -y python3-pip
  docker exec lab04-mysql pip3 install mysql-connector-python
  docker cp trigger_error.py lab04-mysql:/tmp/trigger_error.py

  echo ""
  echo "# Verifying Python installation:"
  docker exec lab04-mysql python3 --version
  docker exec lab04-mysql python3 -c "import mysql.connector; print('mysql-connector-python installed')"
} 2>&1 | tee results/step2-python-setup-$ts.log

echo ""
echo "✓ Step 2 complete. Results saved to: results/step2-python-setup-$ts.log"