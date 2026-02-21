# TiDB Sandbox — AI Agent Instructions

Reproducible experiments exploring TiDB ecosystem behavior, compatibility gaps,
and troubleshooting patterns.

## Repository Layout

```text
labs/<product>/lab-XX-name/   # Each lab is self-contained
labs/_templates/              # Archetype-specific starter kits
LAB_AUTHORING_GUIDE.md        # Full conventions reference
```

Products: `dm`, `dumpling`, `import-into`, `sync-diff-inspector`, `ticdc`, `tidb`.

## Lab Archetypes

| Archetype | When to use | Key marker |
|-----------|-------------|------------|
| **Scripted Validation** | Docker-orchestrated comparison tests with pass/fail matrix | `scripts/run-all.sh` |
| **Manual Exploration** | Syntax/behavior verification, guided manual testing | Single `.md` + `sql/` |
| **Software Project** | Python/Java test harness, CI pipeline, reusable tooling | `pyproject.toml` or `build.gradle` |
| **Multi-Phase Investigation** | Root-cause analysis across multiple hypotheses | `phase{N}-*.sh` scripts |

## Key Conventions

- All bash scripts: `set -euo pipefail`
- Timestamps: UTC ISO format (`date -u +%Y%m%dT%H%M%SZ`)
- Docker images: pin exact versions, never use `:latest`
- WIP labs: use `draft-*` directory prefix (add `draft-*/` to product `.gitignore`)
- Container naming: `{labid}-{service}` (e.g., `lab01-mysql`)
- Python virtual environments: store in `~/.venvs/<org>/<repo>/`,
  symlink `.venv` in project directory (keeps Google Drive sync clean)

## References

See [LAB_AUTHORING_GUIDE.md](LAB_AUTHORING_GUIDE.md) for full documentation
standards, script patterns, and per-archetype quality checklists.
