#!/usr/bin/env bash
set -euo pipefail
# Usage: HIBERNATE=7.1.3.Final ./scripts/run-tests.sh
: "${HIBERNATE:=7.1.3.Final}"
: "${MYSQL_JDBC:=8.4.0}"

# update versions for this run
sed -i.bak "s/^hibernateVersion=.*/hibernateVersion=${HIBERNATE}/" gradle.properties
sed -i.bak "s/^mysqlJdbcVersion=.*/mysqlJdbcVersion=${MYSQL_JDBC}/" gradle.properties
rm -f gradle.properties.bak

./gradlew --no-daemon clean test
./scripts/summarize.sh
