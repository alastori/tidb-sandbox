# Lab Authoring Guidelines

This document provides comprehensive guidelines for creating new labs in the tidb-sandbox repository. Follow these conventions to ensure consistency, reproducibility, and maintainability.

---

## Table of Contents

1. [First Principles](#1-first-principles)
2. [Directory Structure](#2-directory-structure)
3. [Documentation Standards](#3-documentation-standards)
4. [Script Conventions](#4-script-conventions)
5. [Infrastructure Patterns](#5-infrastructure-patterns)
6. [Environment Configuration](#6-environment-configuration)
7. [Quality Checklist](#7-quality-checklist)

---

## 1. First Principles

These principles guide all design decisions in lab creation:

### 1.1 Reproducibility

Any engineer should be able to reproduce results from a clean state. This means:
- All dependencies are explicitly declared
- All versions are pinned (no `:latest` tags)
- Steps are documented in executable order
- State from previous runs doesn't affect new runs

### 1.2 Self-Containment

Each lab is independent and complete:
- All required files live within the lab directory
- No hidden dependencies on other labs
- Shared utilities are copied, not linked (unless in `_templates/`)

### 1.3 Show, Don't Tell

Concrete examples over abstract explanations:
- Include actual commands, not pseudocode
- Show real output, not descriptions of output
- Provide complete code blocks, not fragments

### 1.4 Fail-Fast

Scripts should fail immediately on errors:
- Use `set -euo pipefail` in all bash scripts
- Validate prerequisites before starting work
- Provide clear error messages with context

### 1.5 UTC Timestamps

All timestamps use UTC ISO format for timezone independence:
```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)  # Example: 20250115T143022Z
```

### 1.6 Clean Code Blocks

Code blocks contain only executable code:
- No inline comments in SQL/shell snippets within documentation
- Explanations go in surrounding prose
- Keep code focused on the specific example

### 1.7 Explicit Over Implicit

Full commands with all parameters:
- Complete connection strings (host, port, user, password)
- Full Docker commands with all flags
- No assumed environment or aliases

---

## 2. Directory Structure

### 2.1 Standard Layout

```
labs/<product>/<lab-XX-descriptive-name>/
├── lab-XX-descriptive-name.md    # Primary documentation
├── scripts/
│   ├── common.sh                 # Shared utilities (optional)
│   ├── step0-start.sh            # Infrastructure setup
│   ├── step1-*.sh                # Sequential operation steps
│   ├── step2-*.sh
│   ├── stepN-cleanup.sh          # Teardown (always last numbered step)
│   └── run-all.sh                # Orchestrator script
├── sql/                          # SQL scripts for schema/data
│   ├── schema.sql
│   └── data.sql
├── conf/                         # Configuration files
│   ├── config.toml
│   └── task.yaml
├── results/                      # Output artifacts (gitignored)
│   └── .gitignore
└── .env.example                  # Environment variable template
```

### 2.2 Naming Conventions

| Element | Pattern | Example |
|---------|---------|---------|
| Lab directory | `lab-XX-descriptive-name` | `lab-01-data-types-validation` |
| Documentation | `lab-XX-descriptive-name.md` | `lab-01-data-types-validation.md` |
| Scripts | `step{N}-{action}.sh` | `step0-start.sh`, `step3-run-syncdiff.sh` |
| SQL files | `{purpose}.sql` or `{scenario}_{type}.sql` | `schema.sql`, `s1_blob_data.sql` |
| Config files | `{scenario}_{type}.toml` | `s1_blob.toml`, `s2b_json_workaround.toml` |

### 2.3 Product Categories

Labs are organized by TiDB ecosystem component:

| Directory | Purpose |
|-----------|---------|
| `labs/dm/` | TiDB Data Migration (DM) workflows |
| `labs/dumpling/` | Database export/backup validation |
| `labs/import-into/` | Data import operations |
| `labs/sync-diff-inspector/` | Data consistency validation |
| `labs/tidb/` | Core TiDB features and compatibility |

---

## 3. Documentation Standards

### 3.1 Document Outline Template

Every lab documentation follows this structure:

```markdown
# Lab-XX — Descriptive Title

**Goal:** One-sentence purpose statement explaining what this lab validates or demonstrates.

## Tested Environment

- TiDB vX.Y.Z (`pingcap/tidb:vX.Y.Z`)
- MySQL X.Y (`mysql:X.Y`)
- sync-diff-inspector (`pingcap/sync-diff-inspector@sha256:...`)
- Docker on macOS/Linux
- Default password: `Password_1234` (override with `MYSQL_ROOT_PASSWORD`)

## Scenarios

- **S1 — Basic case**: Description of what S1 tests
- **S2 — Edge case**: Description of what S2 tests
- **S1B — S1 with workaround**: Description of the workaround applied

## Step 0 — Start Infrastructure

Brief description of what this step does.

[Code blocks and instructions]

## Step 1 — Load Data

Brief description.

[Code blocks and instructions]

## Step N — Run Validation

Brief description.

[Code blocks and instructions]

## Results Matrix

| Scenario | MySQL | TiDB | Status | Notes |
|----------|-------|------|--------|-------|
| S1       | ✅    | ❌   | FAIL   | Collation mismatch |
| S1B      | ✅    | ✅   | PASS   | With workaround |

## Analysis & Findings

- **Key finding 1**: Explanation with technical details
- **Key finding 2**: Explanation with implications
- **Workaround**: Description of how to address issues found

## Cleanup

Instructions or reference to cleanup script.

## References

- [TiDB Documentation](https://docs.pingcap.com/tidb/...)
- [MySQL Reference](https://dev.mysql.com/doc/...)
- [Related GitHub Issue](https://github.com/pingcap/...)
```

### 3.2 Code Block Rules

#### Language Specifiers

Always use language specifiers for syntax highlighting:

````markdown
```sql
SELECT * FROM orders WHERE status = 'pending';
```

```bash
docker run -d --name mysql8 -e MYSQL_ROOT_PASSWORD=pass mysql:8.0
```

```yaml
source-id: "mysql-01"
from:
  host: "mysql"
  port: 3306
```

```toml
[data-sources.mysql]
host = "127.0.0.1"
port = 3306
```
````

#### No Inline Comments

Code blocks should be clean and executable. Put explanations in prose:

**Correct:**

The following creates a table with a generated column:

```sql
CREATE TABLE orders (
    id INT PRIMARY KEY,
    quantity INT,
    price DECIMAL(10,2),
    total DECIMAL(10,2) GENERATED ALWAYS AS (quantity * price) STORED
);
```

The `total` column is automatically calculated from `quantity * price`.

**Incorrect:**

```sql
CREATE TABLE orders (
    id INT PRIMARY KEY,
    quantity INT,
    price DECIMAL(10,2),
    -- This is a generated column that computes the total
    total DECIMAL(10,2) GENERATED ALWAYS AS (quantity * price) STORED  -- auto-calculated
);
```

#### Output Blocks

Show command output in plain code blocks or with the same language specifier:

```
+----+---------+-------+-------+
| id | quantity| price | total |
+----+---------+-------+-------+
|  1 |      10 | 25.00 |250.00 |
+----+---------+-------+-------+
1 row in set (0.00 sec)
```

### 3.3 Results Presentation

#### Status Symbols

Use consistent symbols in results tables:

| Symbol | Meaning |
|--------|---------|
| ✅ | Pass / Supported / Success |
| ❌ | Fail / Unsupported / Error |
| ⚠️ | Partial / Warning / Caveat |
| N/A | Not applicable |

#### Results Matrix Format

```markdown
| Scenario | MySQL 8.0 | TiDB 8.5 | Status | Notes |
|----------|-----------|----------|--------|-------|
| S1       | ✅        | ❌       | FAIL   | Collation mismatch detected |
| S1B      | ✅        | ✅       | PASS   | Using `utf8mb4_bin` workaround |
| S2       | ✅        | ✅       | PASS   | |
```

### 3.4 Version Documentation

The "Tested Environment" section must include:

1. **Exact versions** - No ranges, no "latest"
2. **Image references** - Full Docker image names with tags
3. **SHA digests** - For critical tools (ensures immutability)
4. **Platform** - macOS/Linux and architecture (arm64/amd64)

Example:

```markdown
## Tested Environment

- TiDB v8.5.4 (`pingcap/tidb:v8.5.4`)
- MySQL 8.0.44 (`mysql:8.0.44`)
- sync-diff-inspector (`pingcap/sync-diff-inspector@sha256:332798ac...`)
- TiCDC v8.5.5-release.3
- Docker Desktop 4.30.0 on macOS 15.5 (arm64)
- Default credentials: root / `Password_1234`
```

### 3.5 Workaround Documentation

When documenting workarounds, use a consistent pattern:

1. **Base scenario** (e.g., `S1`) - Shows the problem
2. **Workaround variant** (e.g., `S1B`) - Shows the solution
3. **Separate files** - Each variant has its own SQL/config files

Naming convention:
- `s1_blob.sql` / `s1_blob.toml` - Base scenario
- `s1b_blob_workaround.sql` / `s1b_blob_workaround.toml` - With fix

### 3.6 Notes and Callouts

Use blockquotes for important notes:

```markdown
> **Note:** MariaDB 10.5+ requires `BINLOG MONITOR` privilege instead of `REPLICATION CLIENT`.

> **Warning:** This operation is destructive and cannot be undone.

> **Tip:** Set `MYSQL_ROOT_PASSWORD` environment variable to use a custom password.
```

---

## 4. Script Conventions

### 4.1 Script Header Template

Every bash script starts with:

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"

# Source common utilities if present
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"
```

### 4.2 Error Handling

#### The `set` Flags

| Flag | Purpose |
|------|---------|
| `-e` | Exit immediately on command failure |
| `-u` | Treat unset variables as errors |
| `-o pipefail` | Pipeline fails if any command fails |

#### Tolerant Cleanup Commands

For cleanup operations that may fail (container doesn't exist, etc.):

```bash
docker rm -f mysql8sd 2>/dev/null || true
docker network rm lab-net 2>/dev/null || true
```

### 4.3 Environment Variables

#### Default with Override Pattern

```bash
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-Password_1234}"
TIDB_IMAGE="${TIDB_IMAGE:-pingcap/tidb:v8.5.4}"
MAX_RETRIES="${MAX_RETRIES:-30}"
RETRY_INTERVAL="${RETRY_INTERVAL:-5}"
```

#### Timestamp Generation

```bash
TS="${TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
```

#### Path Resolution

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"
RESULTS_DIR="${RESULTS_DIR:-${LAB_DIR}/results}"
```

### 4.4 Script Naming

| Script | Purpose |
|--------|---------|
| `step0-start.sh` | Start infrastructure (containers, clusters) |
| `step1-load-data.sh` | Load initial data/schema |
| `step2-*.sh` | Execute operations |
| `stepN-cleanup.sh` | Always the cleanup script |
| `run-all.sh` | Orchestrator that runs all steps |
| `common.sh` | Shared functions and variables |

### 4.5 Health Check Pattern

```bash
wait_for_mysql() {
    local container=$1
    local password=$2
    local max_retries=${3:-30}

    echo "Waiting for MySQL to be ready..."
    for i in $(seq 1 $max_retries); do
        if docker exec "$container" mysql -uroot -p"$password" -e "SELECT 1" &>/dev/null; then
            echo "MySQL is ready!"
            return 0
        fi
        echo "  Attempt $i/$max_retries..."
        sleep 1
    done
    echo "ERROR: MySQL failed to start"
    return 1
}
```

### 4.6 Logging and Output

#### Echo Headers

```bash
echo "=== Starting MySQL container ==="
echo "=== Loading test data ==="
echo "=== Running validation ==="
```

#### Tee for Dual Output

```bash
./step1-load-data.sh 2>&1 | tee "${RESULTS_DIR}/step1-load-data-${TS}.log"
```

#### Run Step Function

```bash
run_step() {
    local script="$1"
    local label="$2"
    echo
    echo ">>> Running $label"
    bash "${SCRIPT_DIR}/$script" 2>&1 | tee "${RESULTS_DIR}/${label}-${TS}.log"
}

run_step step0-start.sh step0-start
run_step step1-load-data.sh step1-load-data
```

### 4.7 Common Utilities (common.sh)

```bash
#!/bin/bash

# Environment defaults
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-Password_1234}"
TIDB_IMAGE="${TIDB_IMAGE:-pingcap/tidb:v8.5.4}"

# Path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"
RESULTS_DIR="${RESULTS_DIR:-${LAB_DIR}/results}"
TS="${TS:-$(date -u +%Y%m%dT%H%M%SZ)}"

# Ensure results directory exists
mkdir -p "${RESULTS_DIR}"

# Find mysql client (cross-platform)
find_mysql() {
    if command -v mysql &>/dev/null; then
        echo "mysql"
    elif [ -x "/opt/homebrew/opt/mysql-client/bin/mysql" ]; then
        echo "/opt/homebrew/opt/mysql-client/bin/mysql"
    elif [ -x "/usr/local/opt/mysql-client/bin/mysql" ]; then
        echo "/usr/local/opt/mysql-client/bin/mysql"
    else
        echo ""
    fi
}

# Clean ANSI codes from log files
clean_log() {
    local file="$1"
    if [ -f "$file" ]; then
        sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$file" | tr -d '\r' > "${file}.tmp"
        mv "${file}.tmp" "$file"
    fi
}

# Export for use in other scripts
export MYSQL_IMAGE MYSQL_ROOT_PASSWORD TIDB_IMAGE
export SCRIPT_DIR LAB_DIR RESULTS_DIR TS
```

---

## 5. Infrastructure Patterns

### 5.1 Container Naming

Use descriptive names with lab identifier prefix:

| Pattern | Example |
|---------|---------|
| `{labid}-{service}` | `lab01-mysql`, `lab01-tidb` |
| `{service}{version}sd` | `mysql8sd`, `tidbsd` (sd = sandbox) |

### 5.2 Network Configuration

#### Create Lab Network

```bash
NET_NAME="${NET_NAME:-lab01-net}"
docker network rm "$NET_NAME" 2>/dev/null || true
docker network create "$NET_NAME"
```

#### Use Host Network (for TiUP playground)

```bash
docker run --rm --network=host mysql:8.0 \
    mysql -h127.0.0.1 -P4000 -uroot -e "SELECT VERSION();"
```

### 5.3 Port Conventions

| Service | Default Port | Alternate | Notes |
|---------|--------------|-----------|-------|
| MySQL | 3306 | 3307 | Use 3307 to avoid conflicts |
| TiDB | 4000 | 14000 | +10000 for downstream |
| TiDB PD | 2379 | 12379 | +10000 for downstream |
| DM Master | 8261 | - | Data Migration |
| TiCDC | 8300 | - | Change Data Capture |

#### Port Offset Pattern (Multiple Clusters)

```bash
# Upstream cluster (default ports)
tiup playground v8.5.4 --tag upstream --pd.port 2379 --db.port 4000

# Downstream cluster (+10000 offset)
tiup playground v8.5.4 --tag downstream --port-offset 10000
# Results in: PD 12379, TiDB 14000
```

### 5.4 MySQL Container Patterns

#### Simple Startup

```bash
docker run -d --name mysql8sd \
    -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
    -p 3307:3306 \
    "${MYSQL_IMAGE}"
```

#### With Init Script

```bash
docker run -d --name lab01-mysql \
    --network "${NET_NAME}" \
    -v "${LAB_DIR}/sql/init.sql:/docker-entrypoint-initdb.d/init.sql" \
    -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
    "${MYSQL_IMAGE}" \
    --default-authentication-plugin=mysql_native_password
```

#### With Replication Settings

```bash
docker run -d --name lab04-mysql \
    -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
    "${MYSQL_IMAGE}" \
    --log-bin=mysql-bin \
    --binlog-format=ROW \
    --gtid-mode=ON \
    --enforce-gtid-consistency=ON \
    --server-id=1
```

### 5.5 TiDB Container Patterns

#### Direct Docker Run

```bash
docker run -d --name tidbsd \
    -p 4000:4000 \
    "${TIDB_IMAGE}"
```

#### TiUP Playground

```bash
tiup playground "${TIDB_VERSION}" \
    --tag upstream \
    --pd 1 --kv 1 --db 1 \
    --pd.port 2379 \
    --db.port 4000 \
    --without-monitor \
    > "${RESULTS_DIR}/upstream-playground-${TS}.log" 2>&1 &
```

### 5.6 Connection Patterns

#### Docker Exec

```bash
docker exec mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1"
docker exec -i mysql8sd mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" < sql/schema.sql
```

#### Direct Client

```bash
mysql -h127.0.0.1 -P4000 -uroot -e "SELECT VERSION();"
mysql -h127.0.0.1 -P3307 -uroot -p"${MYSQL_ROOT_PASSWORD}" lab < sql/data.sql
```

#### From Container (Network)

```bash
docker run --rm --network="${NET_NAME}" mysql:8.0 \
    mysql -hlab01-mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1"
```

### 5.7 Volume Mounting

| Mount Type | Pattern | Example |
|------------|---------|---------|
| Config (read-only) | `-v path:/container/path:ro` | `-v ./conf:/conf:ro` |
| Init scripts | `-v script:/docker-entrypoint-initdb.d/` | See MySQL init above |
| Results (read-write) | `-v path:/container/path` | `-v ./results:/results` |

### 5.8 Cleanup Patterns

#### Container Cleanup

```bash
docker stop lab01-mysql lab01-tidb 2>/dev/null || true
docker rm lab01-mysql lab01-tidb 2>/dev/null || true
docker network rm lab01-net 2>/dev/null || true
```

#### TiUP Cleanup

```bash
tiup clean upstream 2>/dev/null || true
tiup clean downstream 2>/dev/null || true
pkill -f "pd-server|tikv-server|tidb-server" 2>/dev/null || true
sleep 2
```

#### Full Cleanup Script

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=== Cleanup ==="

# Stop and remove containers
docker stop lab01-mysql lab01-tidb 2>/dev/null || true
docker rm lab01-mysql lab01-tidb 2>/dev/null || true

# Remove network
docker network rm lab01-net 2>/dev/null || true

# Clean temporary files (keep results)
rm -f "${LAB_DIR}/conf/"*_tmp_*.toml

echo "=== Cleanup completed ==="
```

---

## 6. Environment Configuration

### 6.1 .env.example Template

```bash
# Timestamp (leave empty for auto-generation in UTC)
TS=

# Results directory (defaults to ./results)
RESULTS_DIR=

# Docker network
NET_NAME=lab01-net

# MySQL settings
MYSQL_IMAGE=mysql:8.0.44
MYSQL_ROOT_PASSWORD=Password_1234
MYSQL_PORT=3307

# TiDB settings
TIDB_IMAGE=pingcap/tidb:v8.5.4
TIDB_PORT=4000

# Tool images (with specific versions)
SYNCDIFF_IMAGE=pingcap/sync-diff-inspector@sha256:332798ac3161ea3fd4a2aa02801796c5142a3b7c817d9910249c0678e8f3fd53
DUMPLING_IMAGE=pingcap/dumpling:v7.5.1
```

### 6.2 Loading Environment

In `common.sh` or script header:

```bash
# Load .env if present
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi
```

### 6.3 Version Pinning Rules

| Requirement | Pattern | Example |
|-------------|---------|---------|
| Docker images | Tag with version | `mysql:8.0.44` |
| Critical tools | SHA digest | `image@sha256:abc123...` |
| TiUP components | Version variable | `TIDB_VERSION=v8.5.4` |
| Never | `:latest` tag | ❌ `mysql:latest` |

---

## 7. Quality Checklist

Use this checklist before submitting a new lab.

### 7.1 Reproducibility

- [ ] Lab runs successfully from clean state
- [ ] Ran `stepN-cleanup.sh` then `run-all.sh` without errors
- [ ] All Docker images have pinned versions (no `:latest`)
- [ ] All TiUP components specify versions
- [ ] Results directory is listed in `.gitignore`
- [ ] No hardcoded absolute paths

### 7.2 Documentation

- [ ] Lab has a primary `.md` file matching directory name
- [ ] "Tested Environment" section lists all tools with exact versions
- [ ] "Goal" or purpose statement is clear and specific
- [ ] All code blocks have language specifiers (`sql`, `bash`, `yaml`, `toml`)
- [ ] No inline comments within code blocks
- [ ] Results matrix uses standard symbols (✅/❌/⚠️)
- [ ] References section links to official documentation
- [ ] Workarounds are documented with separate variants (S1 → S1B)

### 7.3 Scripts

- [ ] All scripts start with `#!/bin/bash` and `set -euo pipefail`
- [ ] Scripts use `SCRIPT_DIR` and `LAB_DIR` for path resolution
- [ ] Environment variables have defaults (`${VAR:-default}`)
- [ ] Timestamps use UTC ISO format (`%Y%m%dT%H%M%SZ`)
- [ ] `common.sh` centralizes shared variables (if multiple scripts)
- [ ] `run-all.sh` orchestrates all steps with logging
- [ ] Cleanup script exists and removes all created resources

### 7.4 Infrastructure

- [ ] Container names are unique and include lab identifier
- [ ] Docker network is created and cleaned up
- [ ] Ports don't conflict with other labs (use non-standard if needed)
- [ ] Health checks wait for services to be ready
- [ ] Cleanup tolerates missing resources (`|| true`)

### 7.5 Files

- [ ] `.env.example` documents all configurable variables
- [ ] `results/.gitignore` exists with `*` and `!.gitignore`
- [ ] SQL files are in `sql/` directory
- [ ] Config files are in `conf/` directory
- [ ] No sensitive data (passwords in `.env.example` are examples only)

---

## Quick Start

To create a new lab:

1. Copy the template directory:
   ```bash
   cp -r labs/_templates labs/<product>/lab-XX-your-topic
   ```

2. Rename the documentation file:
   ```bash
   mv labs/<product>/lab-XX-your-topic/lab-XX-template.md \
      labs/<product>/lab-XX-your-topic/lab-XX-your-topic.md
   ```

3. Update all placeholder values (search for `XX`, `TODO`, `CHANGEME`)

4. Implement your scripts and SQL files

5. Run the quality checklist above

6. Test with a clean run:
   ```bash
   ./scripts/stepN-cleanup.sh
   ./scripts/run-all.sh
   ```

---

## References

- [TiDB Documentation](https://docs.pingcap.com/tidb/stable)
- [TiUP Documentation](https://docs.pingcap.com/tidb/stable/tiup-overview)
- [sync-diff-inspector](https://docs.pingcap.com/tidb/stable/sync-diff-inspector-overview)
- [TiDB Data Migration](https://docs.pingcap.com/tidb/stable/dm-overview)
