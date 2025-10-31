#!/usr/bin/env bash
set -euo pipefail

HOST="core-tidb"
PORT="4000"
SCHEMA="test"
USER="root"
PASSWORD=""
DIALECT="org.hibernate.dialect.MySQLDialect"

usage() {
  cat <<USAGE
Usage: $0 [--host HOST] [--port PORT] [--schema NAME] [--user USER] [--password PASS]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --schema) SCHEMA="$2"; shift 2;;
    --user) USER="$2"; shift 2;;
    --password) PASSWORD="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$ROOT_DIR/workspace/hibernate-orm"
CONF_DIR="$REPO_DIR/gradle/databases"
CONF_FILE="$CONF_DIR/local-tidb.properties"

if [[ ! -d "$REPO_DIR" ]]; then
  echo "ERROR: workspace/hibernate-orm not found. Run bootstrap.sh first." >&2
  exit 1
fi

mkdir -p "$CONF_DIR"

JDBC_URL="jdbc:mysql://$HOST:$PORT/$SCHEMA?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"

cat <<PROPS > "$CONF_FILE"
hibernate.dialect=$DIALECT
hibernate.connection.driver_class=com.mysql.cj.jdbc.Driver
hibernate.connection.url=$JDBC_URL
hibernate.connection.username=$USER
hibernate.connection.password=$PASSWORD
hibernate.connection.provider_disables_autocommit=true
hibernate.hikari.maximumPoolSize=5
PROPS

echo "Wrote $CONF_FILE"
