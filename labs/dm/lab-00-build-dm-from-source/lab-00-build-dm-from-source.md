<!-- lab-meta
archetype: scripted-validation
status: released
products: [dm]
-->

# Lab 00 -- Build DM from Source

**Goal:** Build DM Docker images from the [pingcap/tiflow](https://github.com/pingcap/tiflow) repository for testing unreleased features. This is a prerequisite lab referenced by other labs that need DM builds ahead of official releases.

**When to use this lab:**

- A DM feature is merged but not in any released tag yet
- You need to validate a specific PR before it merges
- You need to combine multiple unmerged PRs into a single testable image
- You want to bisect a regression to a specific commit

## Build Scenarios

| Script | Use Case | Example |
|--------|----------|---------|
| `build-from-branch.sh` | Build from any branch (master, release-8.5, etc.) | Unreleased v8.5.6 features |
| `build-from-pr.sh` | Build from a specific PR | Test PR #12351 before merge |
| `build-from-multi-pr.sh` | Merge multiple PRs onto a base branch | Combine FK fixes (#12351 + #12414 + #12329) |
| `verify-image.sh` | Verify a built image works (binaries + cluster startup) | Smoke test after any build |

## Prerequisites

- **Go 1.23+** -- `brew install go` or [go.dev/dl](https://go.dev/dl/)
- **Docker Desktop** -- running and accessible from CLI
- **Git** -- for cloning and PR fetching
- **gh** (optional) -- GitHub CLI for PR metadata display
- **~3 GB disk** -- for the tiflow clone + Go module cache
- **~5 min** -- typical build time on Apple Silicon

## Quick Start

### Build from a release branch (most common)

```bash
cd labs/dm/lab-00-build-dm-from-source

# Build from release-8.5 HEAD (contains all v8.5.6 cherry-picks)
bash scripts/build-from-branch.sh release-8.5

# Verify the image
bash scripts/verify-image.sh dm:release-8.5-<hash>
```

### Build from a specific PR

```bash
# Build PR #12351 (safe mode FK fix)
bash scripts/build-from-pr.sh 12351

# Verify
bash scripts/verify-image.sh dm:pr-12351
```

### Build from multiple PRs combined

```bash
# Merge PRs #12351, #12414, #12329 onto release-8.5
BASE_BRANCH=release-8.5 bash scripts/build-from-multi-pr.sh 12351 12414 12329

# Verify
bash scripts/verify-image.sh dm:multi-pr-12351+12414+12329
```

### Use in another lab

After building, set `DM_IMAGE` in the target lab's `.env`:

```bash
# Example: use in Lab 07 (FK validation)
echo "DM_IMAGE=dm:release-8.5-<hash>" >> ../lab-07-fk-v856-validation/.env
```

Or pass via environment:

```bash
DM_IMAGE=dm:release-8.5-d6d53ad docker compose -f docker-compose.yml up -d
```

## Tested Environment

- Go: 1.25.6 (`go1.25.6 darwin/arm64`); tiflow minimum: 1.23
- Docker: 28.5.1 on macOS 15.5 (arm64)
- tiflow repository: [github.com/pingcap/tiflow](https://github.com/pingcap/tiflow) at `release-8.5` (`d6d53adbe`)
- Build output: Alpine 3.15 runtime image (~430 MB with DM binaries)
- Binaries: dm-master, dm-worker, dmctl (statically linked on Linux)

## How It Works

### tiflow repository layout (DM components)

```text
pingcap/tiflow/
  cmd/dm-master/       # dm-master entrypoint
  cmd/dm-worker/       # dm-worker entrypoint
  cmd/dm-ctl/          # dmctl entrypoint
  dm/                  # DM core packages
  dm/Dockerfile        # Multi-stage Alpine build
  Makefile             # Build targets: dm-master, dm-worker, dmctl
  bin/                 # Build output directory
```

### Build pipeline

```text
1. Clone/fetch tiflow repo
2. Checkout target (branch, PR ref, or merged temp branch)
3. `make dm-master dm-worker dmctl`  (Go build with LDFLAGS version injection)
4. `docker build -f dm/Dockerfile .` (multi-stage: golang:1.25-alpine -> alpine:3.15)
5. Verify: binary versions, --help smoke test, cluster startup
```

### Version injection

All builds automatically embed git metadata via LDFLAGS:

```text
ReleaseVersion:    git tag or "None" for dev builds
BuildTS:           UTC build timestamp
GitHash:           full commit SHA
GitBranch:         current branch name
```

Visible in `dm-master -V` output (dm-master and dm-worker use `-V`; dmctl uses `--version`).

### Architecture notes

- **macOS (arm64) host building for Docker:**
  - Docker Desktop runs Linux containers natively on Apple Silicon
  - The `dm/Dockerfile` build stage uses `golang:1.25-alpine`, which builds `linux/arm64` binaries by default (fast)
  - For `linux/amd64` images, use `docker buildx build --platform linux/amd64`
- **CGO:** DM binaries use `CGO_ENABLED=0` on Linux (fully static). macOS native builds require `CGO_ENABLED=1` for the gosigar dependency, but Docker builds are always Linux.
- **Build cache:** Go module cache (~1.5 GB) persists across builds if the tiflow directory is reused.

## Scenarios in Detail

### build-from-branch.sh

Clones (or updates) tiflow, checks out the specified branch, builds binaries, creates Docker image.

**Default tag:** `dm:<branch-name>-<short-hash>` (e.g., `dm:release-8.5-d6d53ad`). The commit hash avoids ambiguity since branch HEAD moves over time.

```bash
# Build from master (latest development)
bash scripts/build-from-branch.sh master

# Build from a release branch
bash scripts/build-from-branch.sh release-8.5

# Build from a specific tag
bash scripts/build-from-branch.sh v8.5.5

# Override image tag
DM_IMAGE_TAG=dm:my-custom-tag bash scripts/build-from-branch.sh release-8.5
```

### build-from-pr.sh

Fetches a PR's head ref (`pull/<N>/head`), checks it out as a local branch, builds from that.

**Default tag:** `dm:pr-<number>`

```bash
# Build from a merged PR (still works — fetches the head ref at merge time)
bash scripts/build-from-pr.sh 12351

# Build from an open PR (gets the latest push)
bash scripts/build-from-pr.sh 12600
```

> **Note:** This builds the PR as-is, without rebasing onto the latest base branch. If the PR is old and conflicts with HEAD, use `build-from-multi-pr.sh` instead with the PR on top of a fresh base.

### build-from-multi-pr.sh

Creates a temporary merge branch from a base, then fetches and merges each PR sequentially. Useful when multiple PRs need to be combined for testing.

**Default tag:** `dm:multi-pr-<N1>+<N2>+...`

```bash
# Combine 3 FK PRs onto release-8.5
BASE_BRANCH=release-8.5 bash scripts/build-from-multi-pr.sh 12351 12414 12329

# Combine 2 PRs onto master
bash scripts/build-from-multi-pr.sh 12500 12501
```

**Conflict handling:** If a PR cannot be cleanly merged, the script stops with an error and prints the tiflow directory path for manual resolution. After resolving, re-run `make dm-master dm-worker dmctl` and `docker build` manually.

### verify-image.sh

Runs a 3-level verification on a built image:

1. **Binary check:** `dm-master -V`, `dm-worker -V`, `dmctl --version`
2. **Smoke test:** `--print-sample-config` on dm-master and dm-worker (proves binary executes and exits cleanly)
3. **Integration test:** Starts a DM master + worker cluster via Docker Compose, verifies `list-member` returns successfully, then tears down

```bash
# Verify any image
bash scripts/verify-image.sh dm:release-8.5-<hash>
bash scripts/verify-image.sh dm:pr-12351
bash scripts/verify-image.sh pingcap/dm:v8.5.5   # also works with official images
```

## Cleanup

```bash
# Remove verification containers
bash scripts/cleanup.sh

# Remove built images
docker rmi dm:release-8.5-<hash> dm:pr-12351 dm:multi-pr-12351+12414+12329

# Remove cloned repo (~3 GB)
rm -rf tiflow/
```

## Cross-References

Labs that depend on builds from this lab:

| Lab | What it needs | Build command |
|-----|---------------|---------------|
| [Lab 07 -- FK v8.5.6 Validation](../lab-07-fk-v856-validation/lab-07-fk-v856-validation.md) | DM from release-8.5 HEAD | `bash scripts/build-from-branch.sh release-8.5` |

## References

- [pingcap/tiflow](https://github.com/pingcap/tiflow) -- source repository
- [tiflow Makefile](https://github.com/pingcap/tiflow/blob/master/Makefile) -- build targets
- [dm/Dockerfile](https://github.com/pingcap/tiflow/blob/master/dm/Dockerfile) -- Docker image spec
- [Go Downloads](https://go.dev/dl/) -- Go installation
