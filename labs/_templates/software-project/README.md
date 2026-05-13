<!-- lab-meta
archetype: software-project
status: draft
products: [TODO]
-->

<!--
PUBLIC-REPO REMINDER:
This repository is public. Do NOT reference customer names, internal hostnames,
internal ticket IDs (FRM, FD, DM, TCOC, etc.), Cloud product/tier names that
frame the bug as a managed-service issue, or real production data. Use generic
placeholders and synthetic data. See LAB_AUTHORING_GUIDE.md section 1.7.
-->

# Lab-XX — TODO: Descriptive Title

**Goal:** TODO: One-sentence description of what this project tests or validates.

## Architecture

TODO: Brief description of components and how they interact.

## Tested Environment

- TiDB vX.Y.Z (`pingcap/tidb:vX.Y.Z`)
- MySQL X.Y (`mysql:X.Y`)
- Python 3.12+ / Java 21+ (TODO: pick one)
- Docker Compose on macOS/Linux

## Quick Start

```bash
# Start infrastructure
docker compose up -d

# Install dependencies
pip install -e ".[dev]"

# Run tests
pytest

# Tear down
docker compose down -v
```

## Results

TODO: Summarize findings. Detailed output is captured in `results/`.

## References

- [TiDB Documentation](https://docs.pingcap.com/tidb/stable)
- TODO: Add relevant links
