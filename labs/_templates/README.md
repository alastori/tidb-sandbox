# Lab Templates

Archetype-specific starter kits for new labs. Copy the directory matching your
experiment type, then customize.

See [LAB_AUTHORING_GUIDE.md](../../LAB_AUTHORING_GUIDE.md) for full conventions.

## Archetypes

| Directory | When to use |
|-----------|-------------|
| [`scripted-validation/`](scripted-validation/) | Docker-orchestrated tests with `run-all.sh` and pass/fail matrix |
| [`manual-exploration/`](manual-exploration/) | Guided SQL exploration, single doc + optional SQL files |
| [`software-project/`](software-project/) | Python/Java harness with `pyproject.toml` and test suite |
| [`investigation/`](investigation/) | Multi-phase root-cause analysis with `phase{N}-*.sh` scripts |

## Quick Start

```bash
# 1. Copy the matching archetype
cp -r labs/_templates/scripted-validation labs/<product>/lab-XX-your-topic

# 2. Rename the documentation file
mv labs/<product>/lab-XX-your-topic/lab-XX-template.md \
   labs/<product>/lab-XX-your-topic/lab-XX-your-topic.md

# 3. Replace placeholders: XX, TODO, CHANGEME, labXX

# 4. Implement, test, and run the quality checklist
```
