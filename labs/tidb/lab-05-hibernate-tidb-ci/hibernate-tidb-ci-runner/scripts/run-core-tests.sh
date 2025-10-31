#!/usr/bin/env bash
set -euo pipefail

HIBERNATE_REF="nightly"
HIBERNATE_VERSION_OVERRIDE=""
SCHEMA="hibernate_orm_test"
TIDB_HOST="core-tidb"
TIDB_PORT="4000"
TIDB_USER="root"
TIDB_PASSWORD=""
DEFAULT_GRADLE_ARGS=":hibernate-core:test"
GRADLE_ARGS="$DEFAULT_GRADLE_ARGS"
GRADLE_ARGS_IS_CUSTOM=0
IDLE_TIMEOUT=120
DIALECT_SELECTION=""
DB_PROFILE_OVERRIDE=""
GRADLE_LOG_LEVEL=""
GRADLE_CONSOLE_MODE=""
SKIP_BUILD=0
EXTRA_BOOTSTRAP_SQL=()
GRADLE_STACKTRACE_MODE="full"

usage() {
  cat <<USAGE
Usage: $0 [options]
  --hibernate-ref <ref>        Git ref already cloned via bootstrap (default: nightly -> main)
  --hibernate-version <ver>    Maven version to pass into the build (optional)
  --schema <name>              Database/schema name (default: hibernate_orm_test)
  --tidb-host <host>           TiDB host (default: core-tidb)
  --tidb-port <port>           TiDB port (default: 4000)
  --tidb-user <user>           TiDB user (default: root)
  --tidb-password <pass>       TiDB password (default: empty)
  --gradle-task <task>         Primary Gradle task (default: :hibernate-core:test)
  --gradle-args <args>         Additional Gradle arguments/tasks (repeatable)
  --idle-timeout <seconds>     Fail the run if no output is produced for this many seconds (default: 120)
  --dialect <name|FQN>         Dialect override (mysql | tidb | fully-qualified class, default: follow profile)
  --db-profile <name>          Gradle database profile (maps to -Pdb=..., default: mysql)
  --gradle-log <level>         Gradle log level (quiet | warn | lifecycle | info | debug, default: lifecycle)
  --gradle-console <mode>      Gradle console mode (auto | rich | plain | verbose)
  --db-bootstrap-sql <sql>     Extra SQL executed during bootstrap (repeatable; include trailing ';')
  --gradle-stacktrace <mode>   Stacktrace detail (full | short | off, default: full)
  --skip-build-runner          Skip rebuilding the runner image
  -h, --help                   Show this help message
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hibernate-ref)
      HIBERNATE_REF="$2"; shift 2;;
    --hibernate-version)
      HIBERNATE_VERSION_OVERRIDE="$2"; shift 2;;
    --schema)
      SCHEMA="$2"; shift 2;;
    --tidb-host)
      TIDB_HOST="$2"; shift 2;;
    --tidb-port)
      TIDB_PORT="$2"; shift 2;;
    --tidb-user)
      TIDB_USER="$2"; shift 2;;
    --tidb-password)
      TIDB_PASSWORD="$2"; shift 2;;
    --gradle-args)
      if [[ $GRADLE_ARGS_IS_CUSTOM -eq 0 ]]; then
        GRADLE_ARGS="$2"
      else
        GRADLE_ARGS+=" $2"
      fi
      GRADLE_ARGS_IS_CUSTOM=1
      shift 2;;
    --gradle-task)
      GRADLE_ARGS="$2"
      GRADLE_ARGS_IS_CUSTOM=1
      shift 2;;
    --idle-timeout)
      IDLE_TIMEOUT="$2"; shift 2;;
    --dialect)
      DIALECT_SELECTION="$2"; shift 2;;
    --db-profile)
      DB_PROFILE_OVERRIDE="$2"; shift 2;;
    --gradle-log)
      GRADLE_LOG_LEVEL="$2"; shift 2;;
    --gradle-console)
      GRADLE_CONSOLE_MODE="$2"; shift 2;;
    --db-bootstrap-sql)
      EXTRA_BOOTSTRAP_SQL+=("$2"); shift 2;;
    --gradle-stacktrace)
      GRADLE_STACKTRACE_MODE="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
      case "$GRADLE_STACKTRACE_MODE" in
        full|short|off)
          ;;
        *)
          echo "Invalid stacktrace mode: $2 (use full|short|off)" >&2
          exit 1
          ;;
      esac
      shift 2;;
    --skip-build-runner)
      SKIP_BUILD=1; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_REPO="$ROOT_DIR/workspace/hibernate-orm"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT_DIR")}"
GRADLE_CACHE_VOLUME="${PROJECT_NAME}_gradle-cache"

if [[ ! -d "$WORKSPACE_REPO" ]]; then
  echo "ERROR: workspace/hibernate-orm not found. Run bootstrap.sh first." >&2
  exit 1
fi

actual_ref="$HIBERNATE_REF"
if [[ "$HIBERNATE_REF" == "nightly" ]]; then
  actual_ref="main"
fi

if [[ -d "$WORKSPACE_REPO/.git" ]]; then
  echo "Ensuring repository is at ref '$actual_ref'"
  pushd "$WORKSPACE_REPO" >/dev/null
  git fetch --all --tags --prune
  if git show-ref --verify --quiet "refs/heads/$actual_ref"; then
    git checkout "$actual_ref"
    git pull --ff-only origin "$actual_ref"
  elif git show-ref --verify --quiet "refs/remotes/origin/$actual_ref"; then
    git checkout "$actual_ref" || git checkout -b "$actual_ref" "origin/$actual_ref"
    git pull --ff-only origin "$actual_ref"
  elif git show-ref --verify --quiet "refs/tags/$actual_ref"; then
    git checkout "tags/$actual_ref"
  else
    echo "WARNING: ref '$actual_ref' not found locally; staying on $(git rev-parse --abbrev-ref HEAD)"
  fi
  popd >/dev/null
fi

DB_PROFILE="${DB_PROFILE_OVERRIDE:-mysql}"
DIALECT_FQN=""
if [[ -n "$DIALECT_SELECTION" ]]; then
  case "$DIALECT_SELECTION" in
    mysql|MYSQL|MySQL|default|DEFAULT|auto|AUTO)
      DIALECT_FQN=""
      ;;
    tidb|TiDB|TIDB)
      DIALECT_FQN="org.hibernate.community.dialect.TiDBDialect"
      ;;
    none|NONE|"" )
      DIALECT_FQN=""
      ;;
    *)
      DIALECT_FQN="$DIALECT_SELECTION"
      ;;
  esac
fi

JDBC_URL="jdbc:mysql://${TIDB_HOST}:${TIDB_PORT}/${SCHEMA}?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"
HOST_WAIT_ADDR="127.0.0.1"

wait_for_port() {
  local host="$1"
  local port="$2"
  local timeout="${3:-180}"
  local start=$(date +%s)
  while true; do
    if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(1); s.connect(('${host}', ${port})); s.close()" >/dev/null 2>&1; then
      return 0
    fi
    local now=$(date +%s)
    if (( now - start >= timeout )); then
      echo "Timed out waiting for ${host}:${port}" >&2
      return 1
    fi
    sleep 2
  done
}

clean_runner_containers() {
  local ids
  ids=$(docker ps -a --filter "name=${PROJECT_NAME}-runner-run" -q)
  if [[ -n "$ids" ]]; then
    docker rm -f $ids >/dev/null 2>&1 || true
  fi
}

clear_gradle_cache_lock() {
  if ! docker volume inspect "$GRADLE_CACHE_VOLUME" >/dev/null 2>&1; then
    return
  fi
  docker run --rm -v "${GRADLE_CACHE_VOLUME}:/cache" alpine:3 sh -c '
set -e
LOCK=/cache/gradle/caches/journal-1/journal-1.lock
if [ -f "$LOCK" ]; then
  rm -f "$LOCK"
fi
' >/dev/null 2>&1 || true
}

cleanup() {
  clean_runner_containers
}
trap cleanup EXIT

determine_worker_schema_count() {
  local os_name cpus
  os_name="$(uname -s)"
  if [[ "$os_name" == "Darwin" ]] && command -v sysctl >/dev/null 2>&1; then
    cpus="$(sysctl -n hw.physicalcpu 2>/dev/null || echo 2)"
  elif command -v nproc >/dev/null 2>&1; then
    cpus="$(nproc 2>/dev/null || echo 2)"
  else
    cpus="2"
  fi
  if [[ -z "$cpus" || "$cpus" -lt 1 ]]; then
    cpus="2"
  fi
  local half=$((cpus / 2))
  if (( half < 1 )); then
    half=1
  fi
  echo "$half"
}

cd "$ROOT_DIR"

docker compose up -d core-pd core-tikv core-tidb

wait_for_port "$HOST_WAIT_ADDR" 4000 300

if [[ "$SKIP_BUILD" -ne 1 ]]; then
  docker compose build runner
fi

MYSQL_CREATE_CMD="mysql -h ${TIDB_HOST} -P ${TIDB_PORT} -u${TIDB_USER}"
if [[ -n "$TIDB_PASSWORD" ]]; then
  MYSQL_CREATE_CMD+=" -p${TIDB_PASSWORD}"
fi
SQL_BOOTSTRAP="CREATE USER IF NOT EXISTS 'hibernate_orm_test'@'%' IDENTIFIED BY 'hibernate_orm_test'; CREATE USER IF NOT EXISTS 'hibernateormtest'@'%' IDENTIFIED BY 'hibernateormtest'; GRANT ALL PRIVILEGES ON *.* TO 'hibernate_orm_test'@'%' WITH GRANT OPTION; GRANT ALL PRIVILEGES ON *.* TO 'hibernateormtest'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES; CREATE DATABASE IF NOT EXISTS ${SCHEMA};"

if (( ${#EXTRA_BOOTSTRAP_SQL[@]} > 0 )); then
  for additional_sql in "${EXTRA_BOOTSTRAP_SQL[@]}"; do
    SQL_BOOTSTRAP+=" ${additional_sql}"
  done
fi

if [[ "$DB_PROFILE" == "mysql_ci" ]]; then
  local_worker_schema_count="$(determine_worker_schema_count)"
  echo "Preparing mysql_ci worker schemas (count=${local_worker_schema_count})..."
  for ((i = 1; i <= local_worker_schema_count; i++)); do
    SQL_BOOTSTRAP+=" CREATE DATABASE IF NOT EXISTS ${SCHEMA}_${i};"
  done
fi

MYSQL_CREATE_CMD+=" -e \"${SQL_BOOTSTRAP}\""

docker compose run --rm --entrypoint /bin/sh runner -lc "$MYSQL_CREATE_CMD" >/dev/null 2>&1 || true

RUN_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_ARTIFACT_DIR="$ARTIFACTS_DIR/$RUN_TIMESTAMP"
mkdir -p "$RUN_ARTIFACT_DIR"

DOCKER_ENVS=(
  -e "MYSQL_HOST=$TIDB_HOST"
  -e "MYSQL_PORT=$TIDB_PORT"
  -e "MYSQL_USER=$TIDB_USER"
  -e "MYSQL_PASSWORD=$TIDB_PASSWORD"
  -e "MYSQL_SCHEMA=$SCHEMA"
  -e "JDBC_URL=$JDBC_URL"
  -e "GRADLE_ARGS=$GRADLE_ARGS"
  -e "RUN_ARTIFACT_DIR=/artifacts/$RUN_TIMESTAMP"
  -e "HIBERNATE_DB_PROFILE=$DB_PROFILE"
)

if [[ -n "$DIALECT_FQN" ]]; then
  DOCKER_ENVS+=( -e "HIBERNATE_DIALECT_FQN=$DIALECT_FQN" )
fi

if [[ -n "$GRADLE_LOG_LEVEL" ]]; then
  DOCKER_ENVS+=( -e "GRADLE_LOG_LEVEL=$GRADLE_LOG_LEVEL" )
fi

if [[ -n "$GRADLE_CONSOLE_MODE" ]]; then
  DOCKER_ENVS+=( -e "GRADLE_CONSOLE_MODE=$GRADLE_CONSOLE_MODE" )
fi

if [[ -n "$HIBERNATE_VERSION_OVERRIDE" ]]; then
  DOCKER_ENVS+=( -e "HIBERNATE_VERSION_OVERRIDE=$HIBERNATE_VERSION_OVERRIDE" )
fi
DOCKER_ENVS+=( -e "GRADLE_STACKTRACE_MODE=$GRADLE_STACKTRACE_MODE" )

set +e
clean_runner_containers
clear_gradle_cache_lock
python3 "$ROOT_DIR/scripts/lib/idle_timeout_runner.py" \
  --timeout "$IDLE_TIMEOUT" \
  --log-file "$RUN_ARTIFACT_DIR/runner.log" \
  -- docker compose run --rm "${DOCKER_ENVS[@]}" runner /scripts/runner-inner.sh
RUN_EXIT=$?
set -e

MODULES=("hibernate-core" "hibernate-testing")

for module in "${MODULES[@]}"; do
  REPORT_DIR="$WORKSPACE_REPO/${module}/target/reports/tests/test"
  RESULTS_DIR="$WORKSPACE_REPO/${module}/target/test-results/test"
  if [[ -d "$REPORT_DIR" ]]; then
    mkdir -p "$RUN_ARTIFACT_DIR/gradle/${module}/html-report"
    cp -R "$REPORT_DIR"/. "$RUN_ARTIFACT_DIR/gradle/${module}/html-report/"
  fi
  if [[ -d "$RESULTS_DIR" ]]; then
    mkdir -p "$RUN_ARTIFACT_DIR/gradle/${module}/junit-xml"
    cp -R "$RESULTS_DIR"/. "$RUN_ARTIFACT_DIR/gradle/${module}/junit-xml/"
  fi
done

read TOTAL FAILED SKIPPED < <(python3 - <<PY
import xml.etree.ElementTree as ET
from pathlib import Path
modules = "${MODULES[*]}".split()
total = failed = skipped = 0
for module in modules:
    results_dir = Path("$WORKSPACE_REPO") / module / "target/test-results/test"
    if results_dir.exists():
        for xml_file in results_dir.glob("TEST-*.xml"):
            root = ET.parse(xml_file).getroot()
            total += int(root.attrib.get("tests", 0))
            failed += int(root.attrib.get("failures", 0)) + int(root.attrib.get("errors", 0))
            skipped += int(root.attrib.get("skipped", 0))
print(total, failed, skipped)
PY)

SUMMARY_FILE="$RUN_ARTIFACT_DIR/summary.txt"
{
  echo "TOTAL=$TOTAL"
  echo "FAILED=$FAILED"
  echo "SKIPPED=$SKIPPED"
  echo "EXIT_CODE=$RUN_EXIT"
} > "$SUMMARY_FILE"

echo "Run artifacts stored in $RUN_ARTIFACT_DIR"
if [[ $RUN_EXIT -ne 0 ]]; then
  echo "Gradle exited with status $RUN_EXIT"
fi

exit $RUN_EXIT
