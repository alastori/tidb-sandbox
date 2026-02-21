<!-- lab-meta
archetype: scripted-validation
status: draft
products: [TODO]
-->

# Lab-XX — TODO: Descriptive Title

**Goal:** TODO: One-sentence description of what this lab validates or demonstrates.

## Tested Environment

- TiDB vX.Y.Z (`pingcap/tidb:vX.Y.Z`)
- MySQL X.Y (`mysql:X.Y`)
- TODO: Add other tools with versions
- Docker on macOS/Linux
- Default password: `Password_1234` (override with `MYSQL_ROOT_PASSWORD`)

## Scenarios

- **S1 — TODO: Scenario name**: Brief description
- **S2 — TODO: Scenario name**: Brief description

## How to Run

```bash
# Run all steps
./scripts/run-all.sh

# Or run individual steps
./scripts/step0-start.sh
./scripts/step1-load-data.sh
./scripts/stepN-cleanup.sh
```

## Step 0 — Start Infrastructure

Start MySQL and TiDB containers.

```bash
./scripts/step0-start.sh
```

## Step 1 — Load Data

Load the test schema and data.

```bash
./scripts/step1-load-data.sh
```

## Step N — TODO: Describe Step

TODO: Describe what this step does and show expected output.

## Results Matrix

| Scenario | MySQL | TiDB | Status | Notes |
|----------|-------|------|--------|-------|
| S1       | TODO  | TODO | TODO   | TODO  |
| S2       | TODO  | TODO | TODO   | TODO  |

## Analysis & Findings

- **TODO: Finding 1**: Description and implications
- **TODO: Finding 2**: Description and implications

## Cleanup

```bash
./scripts/stepN-cleanup.sh
```

## References

- [TiDB Documentation](https://docs.pingcap.com/tidb/stable)
- [MySQL Reference](https://dev.mysql.com/doc/refman/8.0/en/)
- TODO: Add relevant links
