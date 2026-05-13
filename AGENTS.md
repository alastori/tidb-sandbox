# TiDB Sandbox — AI Agent Instructions

Reproducible experiments exploring TiDB ecosystem behavior, compatibility gaps,
and troubleshooting patterns.

## Repository Layout

```text
labs/<product>/lab-XX-name/   # Each lab is self-contained
labs/_templates/              # Archetype-specific starter kits
LAB_AUTHORING_GUIDE.md        # Full conventions reference
```

Products: `dm`, `dumpling`, `import-into`, `lightning`, `sync-diff-inspector`, `ticdc`, `tidb`.

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

## Public-Repo Hygiene

**This repository is public.** Anything committed here is published and
indexed. Labs MUST NOT reference customer names, internal infrastructure
(hostnames, K8s namespaces, dev/staging consoles, internal observability
paths), internal ticket IDs (FRM, FD, DM, TCOC, etc.), Cloud product or tier
names that frame the bug as a managed-service issue, or real production data.
Default to a self-contained environment (TiUP playground, Docker Compose).
Internal validation, if useful, lives in a private workspace and references
the public lab via env-var overrides — never via internal defaults committed
into the lab. See
[LAB_AUTHORING_GUIDE.md section 1.7 Public-Repo Hygiene](LAB_AUTHORING_GUIDE.md#17-public-repo-hygiene)
for the full convention and a pre-commit scrub regex.

## References

See [LAB_AUTHORING_GUIDE.md](LAB_AUTHORING_GUIDE.md) for full documentation
standards, script patterns, and per-archetype quality checklists.
