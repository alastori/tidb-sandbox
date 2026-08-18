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

## Choose the Supported Path First

For released builds, prefer the distribution methods in the [official sync-diff-inspector user guide](https://docs.pingcap.com/tidb/stable/sync-diff-inspector-overview/): TiUP, the TiDB Toolkit, or the `pingcap/sync-diff-inspector` Docker image repository. Pin a released version or digest for reproducible use; this lab never uses `:latest`. For TiDB v8.5.6 and later, the [TiDB tools download documentation](https://docs.pingcap.com/tidb/stable/download-ecosystem-tools/) identifies sync-diff-inspector as part of the TiFlow package and recommends TiUP when the deployment environment has internet access.

Use this source-build lab only when the required commit is not yet available as a published component. Check the available versions before building:

```bash
tiup list sync-diff-inspector
```

This check does not install or update anything, and an available version does not by itself prove that it contains the required fix. Confirm release inclusion with engineering. When the fix is published, run the confirmed version with `tiup sync-diff-inspector:<version> -V`. TiUP accepts stable, nightly, or explicit versions when that version is published for a component. See the [official TiUP component-management guide](https://docs.pingcap.com/tidb/stable/tiup-component-management/) for version-selection and execution syntax.

## Tested Environment

- TiFlow PR [#12804](https://github.com/pingcap/tiflow/pull/12804), head commit `62ea21b60babc437f897f216182e63b59e791c7c`
- Go 1.25.12 builder (`golang:1.25.12-bookworm@sha256:6359592445455f2dbe2412bed411336035bc019a50017720d77454ffdd6d0f82`)
- Target: Linux amd64, statically linked with `CGO_ENABLED=0`
- Docker client 28.5.1 and server 28.3.3 with a Linux arm64 engine
- Apple Git 2.50.1, GNU Make 3.81, GNU Bash 3.2.57, and bsdtar 3.5.3
- `file` 5.41 and `shasum` 6.02
- Host: macOS 26.5.2, arm64

The recorded smoke test used the pinned Go 1.25.12 builder container. The host had Go 1.25.6, so the direct host-Go build was not separately tested; use Go 1.25.12 for that path, matching the pinned PR's `go.mod`.

## Scenarios

- **S1 - Build from PR:** Fetch `pull/12804/head`, embed its commit metadata, and package a Linux amd64 binary.
- **S2 - Verify artifact:** Check SHA-256, execute `-V` and `--help` under Linux amd64, and verify that version output contains the expected commit.
- **S3 - Build from branch:** Use the same process for `master`, a release branch, or another named branch.

## Direct Upstream-Makefile PR Build

TiFlow's [contribution guide](https://github.com/pingcap/tiflow/blob/master/CONTRIBUTING.md#build-tidb-cdc) uses `make` as the source-build entry point. The repository provides a dedicated [`make sync-diff-inspector` target](https://github.com/pingcap/tiflow/blob/62ea21b60babc437f897f216182e63b59e791c7c/Makefile#L387-L388), which owns the Go flags and embedded version metadata.

This path requires Git, Make, internet access, and Go 1.25.12. It cross-compiles a Linux amd64 binary. Running that binary requires either a Linux amd64 host or Docker with Linux amd64 emulation.

The following direct workflow for PR #12804 does not depend on this lab's scripts:

```bash
set -euo pipefail

git clone --filter=blob:none https://github.com/pingcap/tiflow.git
cd tiflow
git fetch origin pull/12804/head
git switch --detach FETCH_HEAD

GOOS=linux GOARCH=amd64 make \
  RELEASE_VERSION="pr-12804-$(git rev-parse --short=12 HEAD)" \
  GITBRANCH=pr-12804 \
  sync-diff-inspector

git rev-parse HEAD | tee bin/sync_diff_inspector.commit
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum bin/sync_diff_inspector
else
  shasum -a 256 bin/sync_diff_inspector
fi | tee bin/sync_diff_inspector.sha256
```

On Linux amd64, inspect the embedded version directly:

```bash
set -euo pipefail

./bin/sync_diff_inspector -V
./bin/sync_diff_inspector --help | sed -n '1,24p'
```

On the tested macOS arm64 host, run the Linux amd64 binary through the same pinned builder image used by the automated workflow:

```bash
set -euo pipefail

BUILDER_IMAGE='golang:1.25.12-bookworm@sha256:6359592445455f2dbe2412bed411336035bc019a50017720d77454ffdd6d0f82'
BINARY_PATH="$PWD/bin/sync_diff_inspector"
run_target_binary() {
  local container_id exit_code
  container_id="$(docker create --platform linux/amd64 \
    --entrypoint /usr/local/bin/sync_diff_inspector \
    "$BUILDER_IMAGE" "$@")"
  if docker cp "$BINARY_PATH" \
      "$container_id:/usr/local/bin/sync_diff_inspector" && \
      docker start --attach "$container_id"; then
    exit_code=0
  else
    exit_code=$?
  fi
  docker rm -f "$container_id" >/dev/null 2>&1 || true
  return "$exit_code"
}
run_target_binary -V
run_target_binary --help 2>&1 | sed -n '1,24p'
```

Success means the `Git Commit Hash` in `-V` matches `bin/sync_diff_inspector.commit`, the checksum is retained beside the binary, and `--help` exits successfully. The PR's [`go.mod`](https://github.com/pingcap/tiflow/blob/62ea21b60babc437f897f216182e63b59e791c7c/go.mod#L1-L3) requires Go 1.25.12.

## Optional Automated Workflow

The lab scripts require Git, Docker, and `tar`; they do not require a local Go installation. They automate the same Makefile target in a pinned container, then add the distributable tarball, `BUILD_INFO.txt`, checksums, logs, and exact-commit verification:

```bash
cd labs/sync-diff-inspector/lab-00-build-from-source
cp .env.example .env
bash scripts/run-all.sh 12804 amd64
```

The default invocation is also PR #12804 for Linux amd64:

```bash
bash scripts/run-all.sh
```

### Build from a Pull Request

```bash
TARGET_ARCH=amd64 bash scripts/build-from-pr.sh 12804
bash scripts/verify-binary.sh
```

The fetch is deliberately pinned to GitHub's pull-request head ref. It works for open and merged pull requests while GitHub retains that ref.

### Build from a Branch

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
4. Invoke TiFlow's official `make sync-diff-inspector` target, which owns the Go build flags and embedded version variables.
5. Package the binary, build metadata, and checksums.
6. Run the binary inside a Linux container matching the target architecture.

The scripts are convenience automation, not a separate build implementation. TiFlow is the upstream source repository that contains sync-diff-inspector. Its checkout is copied into an ephemeral builder container so the lab also works when Docker cannot bind-mount the host path. The container is removed after the binary is copied to this lab's `dist/` directory.

## Results Matrix

| Scenario | Target | Status | Evidence |
|----------|--------|--------|----------|
| S1 - PR #12804 build | Linux amd64 | ✅ | `results/build-pr-*.log` |
| S2 - Binary verification | Linux amd64 | ✅ | `results/verify-*.log` |
| S3 - Branch build | Linux amd64/arm64 | N/A | Reusable path, not part of the #12804 smoke test |

The evidence paths above are generated by a local run and ignored by Git because the logs and binaries are large and reproducible. Run the workflow to populate them locally.

### PR #12804 Smoke-Test Result

The full `bash scripts/run-all.sh 12804 amd64` workflow passed from a fresh clone at `2026-08-18T01:09:08Z` using TiFlow's `make sync-diff-inspector` target. It produced a 245 MB statically linked x86-64 binary and a 95 MB compressed tarball. The verification output included:

```text
Release Version: pr-12804-62ea21b60bab
Git Commit Hash: 62ea21b60babc437f897f216182e63b59e791c7c
Git Branch: pr-12804
UTC Build Time: 2026-08-18 01:09:14
Go Version: go1.25.12
Failpoint Build: false

Commit metadata check: PASS (62ea21b60babc437f897f216182e63b59e791c7c)
PASS: binary checksum, execution, help output, and commit metadata verified.
```

## Cleanup

The lab does not leave running containers. Generated source and binary artifacts are retained for inspection by default.

```bash
# Preview only
bash scripts/step3-cleanup.sh

# Remove only paths proven to be owned by this lab
bash scripts/step3-cleanup.sh --confirm
```

The lab marks directories that it creates. Cleanup preserves a pre-existing checkout or output directory supplied through `TIFLOW_DIR`, `DIST_DIR`, or `RESULTS_DIR`; remove those user-managed paths manually if desired.

## Troubleshooting

### Docker cannot execute the target architecture

The build can cross-compile without emulation, but the execution smoke test requires Docker support for the target architecture. Run the verification on a matching Linux host if Docker reports an `exec format error`.

### Existing TiFlow checkout is dirty

The lab refuses to overwrite or clean local changes. Preserve the checkout elsewhere or point `TIFLOW_DIR` at a new dedicated path.

### Customer artifact policy

This lab proves provenance and basic executability. It does not turn the binary into a supported release. Use an engineering-approved delivery channel and state which official release is expected to supersede the test artifact.

## References

- [tiflow#12804 - Fix sync-diff-inspector bucket count interpretation](https://github.com/pingcap/tiflow/pull/12804)
- [TiDB Docs - sync-diff-inspector User Guide](https://docs.pingcap.com/tidb/stable/sync-diff-inspector-overview/)
- [TiDB Docs - Download TiDB Tools](https://docs.pingcap.com/tidb/stable/download-ecosystem-tools/)
- [TiDB Docs - Manage TiUP Components](https://docs.pingcap.com/tidb/stable/tiup-component-management/)
- [TiFlow - Contribution Guide](https://github.com/pingcap/tiflow/blob/master/CONTRIBUTING.md#build-tidb-cdc)
- [TiFlow PR #12804 Makefile - sync-diff-inspector target](https://github.com/pingcap/tiflow/blob/62ea21b60babc437f897f216182e63b59e791c7c/Makefile#L387-L388)
- [TiFlow PR #12804 go.mod - Go toolchain requirement](https://github.com/pingcap/tiflow/blob/62ea21b60babc437f897f216182e63b59e791c7c/go.mod#L1-L3)
