# Lab Authoring Guide

Conventions for creating and maintaining labs in tidb-sandbox. Each lab is a
self-contained experiment exploring TiDB ecosystem behavior, compatibility, or
troubleshooting patterns.

## Table of Contents

1. [First Principles](#1-first-principles)
2. [Lab Archetypes](#2-lab-archetypes)
3. [Documentation Standards](#3-documentation-standards)
4. [Common Patterns](#4-common-patterns)
5. [Script Conventions](#5-script-conventions)
6. [Draft Labs](#6-draft-labs)
7. [Quality Guidelines](#7-quality-guidelines)

---

## 1. First Principles

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

### 1.6 Explicit Over Implicit

Full commands with all parameters:

- Complete connection strings (host, port, user, password)
- Full Docker commands with all flags
- No assumed environment or aliases

---

## 2. Lab Archetypes

Every lab falls into one of four archetypes. Choose the one that matches your
experiment's structure, then use the corresponding template in
[`labs/_templates/`](labs/_templates/).

### 2.1 Scripted Validation

**When:** Docker-orchestrated comparison tests with a clear pass/fail matrix.

**Layout:**

```text
lab-XX-name/
├── lab-XX-name.md          # Primary doc with results matrix
├── .env.example
├── scripts/
│   ├── common.sh
│   ├── step0-start.sh
│   ├── step1-load-data.sh
│   ├── stepN-cleanup.sh
│   └── run-all.sh          # Key marker: orchestrator
├── sql/
├── conf/
└── results/
```

**Exemplars:**
[sync-diff-inspector/lab-01](labs/sync-diff-inspector/lab-01-data-types-validation),
[dumpling/lab-01](labs/dumpling/lab-01-view-dependencies)

**Template:** [`_templates/scripted-validation/`](labs/_templates/scripted-validation/)

### 2.2 Manual Exploration

**When:** Syntax/behavior verification across engines, guided manual testing.

**Layout:**

```text
lab-XX-name/
├── lab-XX-name.md          # Primary doc with inline SQL
└── sql/                    # Optional supporting SQL files
```

**Exemplars:**
[tidb/lab-01](labs/tidb/lab-01-syntax-select-for-update-of),
[tidb/lab-04](labs/tidb/lab-04-fk-index-comparison),
[import-into/lab-01](labs/import-into/lab-01-base64-decoding)

**Template:** [`_templates/manual-exploration/`](labs/_templates/manual-exploration/)

### 2.3 Software Project

**When:** Python/Java test harness, CI pipeline, reusable tooling.

**Layout:**

```text
lab-XX-name/
├── README.md               # Primary doc (project convention)
├── pyproject.toml           # or build.gradle
├── docker-compose.yml
├── src/
├── tests/
└── results/
```

**Exemplars:**
[tidb/lab-05](labs/tidb/lab-05-hibernate-tidb-ci),
[tidb/lab-03](labs/tidb/lab-03-vector-store-basics)

**Template:** [`_templates/software-project/`](labs/_templates/software-project/)

### 2.4 Multi-Phase Investigation

**When:** Root-cause analysis across multiple hypotheses, phased testing.

**Layout:**

```text
lab-XX-name/
├── lab-XX-name.md          # Master doc: hypothesis → findings
├── phase1-*.sh
├── phase2-*.sh
├── ...
└── results/
```

**Exemplars:**
[tidb/lab-07](labs/tidb/lab-07-varchar-length-enforcement) (canonical —
numbered phase scripts),
[dumpling/lab-02](labs/dumpling/lab-02-partitioned-export-performance)
(lightweight variant — `setup.sql` + `cleanup.sh` + findings doc)

**Template:** [`_templates/investigation/`](labs/_templates/investigation/)

---

## 3. Documentation Standards

### 3.1 Lab Metadata

Every lab's primary `.md` file starts with an HTML comment metadata block
**before** the H1 title:

```html
<!-- lab-meta
archetype: scripted-validation
status: released
products: [sync-diff-inspector, tidb, mysql]
-->
```

Fields:

| Field | Values |
|-------|--------|
| `archetype` | `scripted-validation`, `manual-exploration`, `software-project`, `investigation` |
| `status` | `released`, `draft` |
| `products` | Array of TiDB ecosystem components tested |

### 3.2 Naming

| Element | Convention | Example |
|---------|------------|---------|
| Directory | `lab-XX-descriptive-name` | `lab-01-data-types-validation` |
| Primary doc | Same as directory + `.md` | `lab-01-data-types-validation.md` |
| Primary doc (projects) | `README.md` | Software project archetype |
| Step scripts | `step{N}-{action}.sh` | `step0-start.sh` |
| Phase scripts | `phase{N}-{topic}.sh` | `phase3-lightning.sh` |
| SQL files | `{purpose}.sql` or `{scenario}_{type}.sql` | `schema.sql`, `s1_blob_data.sql` |

### 3.3 Tested Environment

Every lab must include a "Tested Environment" section with exact versions:

```markdown
## Tested Environment

- TiDB v8.5.4 (`pingcap/tidb:v8.5.4`)
- MySQL 8.0.44 (`mysql:8.0.44`)
- sync-diff-inspector (`pingcap/sync-diff-inspector@sha256:332798ac...`)
- Docker Desktop 4.30.0 on macOS 15.5 (arm64)
- Default credentials: root / `Password_1234`
```

Rules:

- **Exact versions** — no ranges, no `:latest`
- **Full image refs** — Docker image name + tag
- **SHA digests** — for critical tools where immutability matters
- **Platform** — OS and architecture

### 3.4 Results

- Commit result files when they serve as **evidence** (logs, diffs, output snapshots)
- Gitignore large or easily regenerable artifacts (`results/.gitignore`)
- Use consistent status symbols in results tables:

| Symbol | Meaning |
|--------|---------|
| ✅ | Pass / Supported |
| ❌ | Fail / Unsupported |
| ⚠️ | Partial / Caveat |
| N/A | Not applicable |

### 3.5 References

Every lab ends with a References section linking to:

- Official PingCAP documentation
- MySQL/MariaDB reference pages
- Relevant GitHub issues

### 3.6 Code Blocks

Always use language specifiers (`sql`, `bash`, `yaml`, `toml`, `text`).

Use `text` for command output:

```text
+----+----------+--------+
| id | quantity | total  |
+----+----------+--------+
|  1 |       10 | 250.00 |
+----+----------+--------+
```

### 3.7 Notes and Callouts

```markdown
> **Note:** MariaDB 10.5+ requires `BINLOG MONITOR` instead of `REPLICATION CLIENT`.

> **Warning:** This operation is destructive and cannot be undone.
```

---

## 4. Common Patterns

### 4.1 Container Naming

Use `{labid}-{service}` for all containers:

```bash
MYSQL_CONTAINER="${MYSQL_CONTAINER:-lab01-mysql}"
TIDB_CONTAINER="${TIDB_CONTAINER:-lab01-tidb}"
```

### 4.2 Port Conventions

| Service | Default | Alternate | Notes |
|---------|---------|-----------|-------|
| MySQL | 3306 | 3307 | Use 3307 to avoid host conflicts |
| TiDB | 4000 | 14000 | +10000 for downstream cluster |
| TiDB PD | 2379 | 12379 | +10000 for downstream cluster |
| DM Master | 8261 | — | |
| TiCDC | 8300 | — | |

For multi-cluster setups, use the +10000 offset pattern:

```bash
# Upstream (default ports)
tiup playground v8.5.4 --tag upstream --pd.port 2379 --db.port 4000

# Downstream (+10000)
tiup playground v8.5.4 --tag downstream --db.port 14000 --pd.port 12379
```

### 4.3 Health Check Pattern

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

### 4.4 Environment Variables

Default-with-override pattern:

```bash
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0.44}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-Password_1234}"
TIDB_IMAGE="${TIDB_IMAGE:-pingcap/tidb:v8.5.4}"
```

Loading `.env` file:

```bash
ENV_FILE="${ENV_FILE:-${LAB_DIR}/.env}"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi
```

### 4.5 Cleanup

Tolerant teardown — every removal command uses `|| true`:

```bash
docker stop lab01-mysql lab01-tidb 2>/dev/null || true
docker rm lab01-mysql lab01-tidb 2>/dev/null || true
docker network rm lab01-net 2>/dev/null || true
```

TiUP cleanup:

```bash
tiup clean upstream 2>/dev/null || true
tiup clean downstream 2>/dev/null || true
```

### 4.6 Logging

Tee output to `results/` with UTC timestamps:

```bash
./step1-load-data.sh 2>&1 | tee "${RESULTS_DIR}/step1-load-data-${TS}.log"
```

Step runner function (for `run-all.sh`):

```bash
run_step() {
    local script="$1"
    local label="$2"
    echo
    echo ">>> Running $label"
    bash "${SCRIPT_DIR}/$script" 2>&1 | tee "${RESULTS_DIR}/${label}-${TS}.log"
}
```

---

## 5. Script Conventions

### 5.1 Script Header

Every bash script starts with:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"
```

### 5.2 common.sh (Scripted Validation)

For labs with multiple step scripts, centralize shared state in `common.sh`.
Since `common.sh` is sourced (not executed directly), it omits the shebang and
`set -euo pipefail` — the calling script's flags apply:

```bash
# Sourced by step scripts — not executed directly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(dirname "${SCRIPT_DIR}")"

# Load .env
ENV_FILE="${ENV_FILE:-${LAB_DIR}/.env}"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Defaults
TS="${TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
RESULTS_DIR="${RESULTS_DIR:-${LAB_DIR}/results}"
mkdir -p "${RESULTS_DIR}"

MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0.44}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-Password_1234}"
TIDB_IMAGE="${TIDB_IMAGE:-pingcap/tidb:v8.5.4}"

export SCRIPT_DIR LAB_DIR TS RESULTS_DIR
export MYSQL_IMAGE MYSQL_ROOT_PASSWORD TIDB_IMAGE
```

Step scripts source it:

```bash
[[ -f "${SCRIPT_DIR}/common.sh" ]] && source "${SCRIPT_DIR}/common.sh"
```

### 5.3 Phase Scripts (Investigation)

Investigation labs use numbered phase scripts instead of step scripts:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Phase scripts live alongside the lab doc, not in scripts/
LAB_DIR="${SCRIPT_DIR}"

echo "=== Phase 1: SQL DML Behavior ==="
# ... phase-specific logic
```

Phase scripts are standalone — they don't share `common.sh`. Each phase tests
a specific hypothesis and can be run independently.

---

## 6. Draft Labs

A lab is **draft** when it's still being developed: incomplete findings,
untested steps, or missing documentation sections. A lab is **released** when
another engineer can follow it end-to-end and reproduce the results without
asking the author for help. The README lab index only lists released labs.

### Naming

Prefix the directory with `draft-`:

```text
labs/tidb/draft-lab-xx-new-experiment/
```

Add a gitignore entry for draft directories if your product folder doesn't
already have one:

```gitignore
# In labs/<product>/.gitignore
draft-*/
```

### Promotion

When a draft is ready for release:

1. Assign the next available lab number
2. Rename the directory: `draft-lab-xx-name` → `lab-08-name`
3. Rename the primary doc to match
4. Add the metadata comment block with `status: released`
5. Remove from `.gitignore` if needed
6. Add to the README lab index

---

## 7. Quality Guidelines

Per-archetype checklists. Complete the one matching your lab's archetype.

### 7.1 Scripted Validation

- [ ] `run-all.sh` completes from clean state without errors
- [ ] All Docker images pinned to exact versions
- [ ] `stepN-cleanup.sh` removes all created resources
- [ ] Results matrix in primary doc uses standard symbols
- [ ] `.env.example` documents all configurable variables
- [ ] `results/.gitignore` present
- [ ] Health checks wait for services before proceeding
- [ ] Tested Environment section lists all tools with versions

### 7.2 Manual Exploration

- [ ] Primary doc has clear Goal statement
- [ ] All SQL blocks use `sql` language specifier
- [ ] Tested Environment lists exact versions used
- [ ] Each scenario has expected vs actual output
- [ ] References section links to official docs
- [ ] No external dependencies beyond mysql client and Docker

### 7.3 Software Project

- [ ] `README.md` has Quick Start section (≤5 commands to run)
- [ ] `docker-compose.yml` pins all image versions
- [ ] `pyproject.toml` / `build.gradle` has pinned dependencies
- [ ] Tests pass: `pytest` / `gradle test`
- [ ] Results directory captures evidence artifacts
- [ ] Architecture section explains component relationships

### 7.4 Multi-Phase Investigation

- [ ] Master doc states the hypothesis clearly
- [ ] Each phase script runs independently
- [ ] Phase scripts use `set -euo pipefail`
- [ ] Findings summary in master doc references specific phases
- [ ] Results directory captures phase outputs
- [ ] Tested Environment covers all engines/versions compared
