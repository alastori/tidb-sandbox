<!-- lab-meta
archetype: scripted-validation
status: released
products: [sync-diff-inspector]
-->

# Lab 00 - Build sync-diff-inspector from Source

**Goal:** Produce and verify a traceable Linux sync-diff-inspector binary from a TiFlow pull request or branch before that change reaches an official TiUP component release.

## When to Use This Lab

- A sync-diff-inspector fix is merged but not present in the current TiUP build.
- A pull request needs customer-case validation before merge.
- Engineering needs a binary pinned to an exact TiFlow commit.

The output is a test artifact, not an official release. Engineering should approve any external distribution and retain the generated commit metadata and checksum with the customer case.

## Tested Environment

- TiFlow PR [#12804](https://github.com/pingcap/tiflow/pull/12804), head commit `62ea21b60babc437f897f216182e63b59e791c7c`
- Go 1.25.12 builder (`golang:1.25.12-bookworm@sha256:6359592445455f2dbe2412bed411336035bc019a50017720d77454ffdd6d0f82`)
- Target: Linux amd64, statically linked with `CGO_ENABLED=0`
- Docker client 28.5.1 and server 28.3.3 with a Linux arm64 engine
- Host: macOS, arm64

## Scenarios

- **S1 - Build from PR:** Fetch `pull/12804/head`, embed its commit metadata, and package a Linux amd64 binary.
- **S2 - Verify artifact:** Check SHA-256, execute `-V` and `--help` under Linux amd64, and verify that version output contains the expected commit.
- **S3 - Build from branch:** Use the same process for `master`, a release branch, or another named branch.

## Quick Start

```bash
cd labs/sync-diff-inspector/lab-00-build-from-source
cp .env.example .env
bash scripts/run-all.sh 12804 amd64
```

The default invocation is also PR #12804 for Linux amd64:

```bash
bash scripts/run-all.sh
```

## Build from a Pull Request

```bash
TARGET_ARCH=amd64 bash scripts/build-from-pr.sh 12804
bash scripts/verify-binary.sh
```

The fetch is deliberately pinned to GitHub's pull-request head ref. It works for open and merged pull requests while GitHub retains that ref.

## Build from a Branch

```bash
TARGET_ARCH=amd64 bash scripts/build-from-branch.sh master
bash scripts/verify-binary.sh
```

The branch is resolved to its remote commit and checked out in detached mode before the build. `BUILD_INFO.txt` records the resolved hash, so later branch movement does not make the artifact ambiguous.

## Outputs

Generated files are ignored by Git:

```text
dist/
  sync-diff-inspector-pr-12804-linux-amd64-<commit>-<timestamp>/
    sync_diff_inspector
    BUILD_INFO.txt
    SHA256SUMS
  sync-diff-inspector-pr-12804-linux-amd64-<commit>-<timestamp>.tar.gz
  sync-diff-inspector-pr-12804-linux-amd64-<commit>-<timestamp>.tar.gz.sha256
results/
  build-pr-*.log
  verify-*.log
  last-binary-path.txt
  last-tarball-path.txt
tiflow/
  # Isolated source checkout used only by this lab
```

Before sharing a test artifact, provide all of the following:

1. The tarball.
2. Its adjacent `.sha256` file.
3. The target platform, such as `linux/amd64`.
4. The source PR and exact commit from `BUILD_INFO.txt`.
5. The successful verification log.

## How It Works

1. Clone or refresh a dedicated TiFlow checkout.
2. Fetch the PR head ref or remote branch and use a detached checkout.
3. Run a pinned Go builder container with `GOOS=linux`, the requested `GOARCH`, and `CGO_ENABLED=0`.
4. Build `./sync_diff_inspector` with the same version variables used by TiFlow's Makefile.
5. Package the binary, build metadata, and checksums.
6. Run the binary inside a Linux container matching the target architecture.

The source checkout is copied into an ephemeral builder container so the lab also works when Docker cannot bind-mount the host path. The container is removed after the binary is copied to this lab's `dist/` directory.

## Results Matrix

| Scenario | Target | Status | Evidence |
|----------|--------|--------|----------|
| S1 - PR #12804 build | Linux amd64 | ✅ | `results/build-pr-*.log` |
| S2 - Binary verification | Linux amd64 | ✅ | `results/verify-*.log` |
| S3 - Branch build | Linux amd64/arm64 | N/A | Reusable path, not part of the #12804 smoke test |

### PR #12804 Smoke-Test Result

The full `bash scripts/run-all.sh 12804 amd64` workflow passed on 2026-08-14. It produced a 245 MB statically linked x86-64 binary and a 95 MB compressed tarball. The verification output included:

```text
Release Version: pr-12804-62ea21b60bab
Git Commit Hash: 62ea21b60babc437f897f216182e63b59e791c7c
Git Branch: pr-12804
Go Version: go1.25.12
Failpoint Build: false

Commit metadata check: PASS (62ea21b60babc437f897f216182e63b59e791c7c)
PASS: binary checksum, execution, help output, and commit metadata verified.
```

## Cleanup

The lab does not leave running containers. Generated source and binary artifacts are retained for inspection by default.

```bash
# Preview only
bash scripts/cleanup.sh

# Remove only paths generated inside this lab
CLEAN_BUILD_OUTPUTS=yes bash scripts/cleanup.sh
```

## Troubleshooting

### Docker cannot execute the target architecture

The build can cross-compile without emulation, but the execution smoke test requires Docker support for the target architecture. Run the verification on a matching Linux host if Docker reports an `exec format error`.

### Existing TiFlow checkout is dirty

The lab refuses to overwrite or clean local changes. Preserve the checkout elsewhere or point `TIFLOW_DIR` at a new dedicated path.

### Customer artifact policy

This lab proves provenance and basic executability. It does not turn the binary into a supported release. Use an engineering-approved delivery channel and state which official release is expected to supersede the test artifact.

## References

- [tiflow#12804 - Fix sync-diff-inspector bucket count interpretation](https://github.com/pingcap/tiflow/pull/12804)
- [TiFlow Makefile - sync-diff-inspector target](https://github.com/pingcap/tiflow/blob/master/Makefile)
- [sync-diff-inspector documentation](https://docs.pingcap.com/tidb/stable/sync-diff-inspector-overview)
