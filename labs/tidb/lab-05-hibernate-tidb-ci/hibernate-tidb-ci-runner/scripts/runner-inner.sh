#!/usr/bin/env bash
set -euo pipefail

: "${MYSQL_HOST:?MYSQL_HOST not set}"
: "${MYSQL_PORT:?MYSQL_PORT not set}"
: "${MYSQL_SCHEMA:?MYSQL_SCHEMA not set}"
: "${MYSQL_USER:?MYSQL_USER not set}"
: "${JDBC_URL:?JDBC_URL not set}"
: "${GRADLE_ARGS:?GRADLE_ARGS not set}"

DB_PROFILE="${HIBERNATE_DB_PROFILE:-mysql}"
DIALECT_FQN="${HIBERNATE_DIALECT_FQN:-}"
LOG_LEVEL="${GRADLE_LOG_LEVEL:-}"
CONSOLE_MODE="${GRADLE_CONSOLE_MODE:-}"
STACKTRACE_MODE="${GRADLE_STACKTRACE_MODE:-full}"

cd /workspace/hibernate-orm

chmod +x ./gradlew

read -r -a EXTRA_ARGS <<< "${GRADLE_ARGS}"

COMMON_ARGS=(
  "--no-daemon"
  "-Pdb=${DB_PROFILE}"
  "-DdbHost=${MYSQL_HOST}:${MYSQL_PORT}"
  "-DdbPassword=hibernateormtest"
  "-Djdbc.driver=com.mysql.cj.jdbc.Driver"
  "-Djdbc.datasource=com.mysql.cj.jdbc.MysqlDataSource"
)

if [[ -n "$DIALECT_FQN" ]]; then
  COMMON_ARGS+=("-Ddb.dialect=${DIALECT_FQN}")
fi

case "${STACKTRACE_MODE,,}" in
  full)
    COMMON_ARGS+=("--full-stacktrace")
    ;;
  short|"")
    COMMON_ARGS+=("--stacktrace")
    ;;
  off)
    ;;
  *)
    COMMON_ARGS+=("--stacktrace")
    ;;
esac

if [[ -n "${HIBERNATE_VERSION_OVERRIDE:-}" ]]; then
  COMMON_ARGS+=("-Phibernate.version.override=${HIBERNATE_VERSION_OVERRIDE}")
fi

case "${LOG_LEVEL,,}" in
  ""|"lifecycle")
    ;;
  quiet)
    COMMON_ARGS+=("--quiet")
    ;;
  warn|"warning")
    COMMON_ARGS+=("--warn")
    ;;
  info)
    COMMON_ARGS+=("--info")
    ;;
  debug)
    COMMON_ARGS+=("--debug")
    ;;
  *)
    COMMON_ARGS+=("--${LOG_LEVEL}")
    ;;
esac

if [[ -n "$CONSOLE_MODE" ]]; then
  COMMON_ARGS+=("--console=${CONSOLE_MODE}")
fi

./gradlew "${COMMON_ARGS[@]}" "${EXTRA_ARGS[@]}"
