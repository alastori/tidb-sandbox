# Containerized Gradle Hibernate ORM Testing

Run the Hibernate ORM test suite inside Docker for a production-like environment or fall back to a host JDK when you need fast debugging loops.

## Choose Your Execution Path

| Approach | Requirements | Best For | Pros | Cons |
|----------|--------------|----------|------|------|
| **Containerized Gradle** (recommended) | Docker installed | Reproducing CI, avoiding host JDK setup | Matches CI image, isolates dependencies, no JDK installation | Requires Docker resources to be sized first, container debugging overhead |
| **Host JDK** | JDK 25 installed | IDE-driven debugging, quick edits | No container overhead, easy to attach debugger | Must manage JVM locally, path quirks on macOS, can drift from CI configuration |

## Quick Start – Containerized Workflow

1. **Check Docker resources**

   ```bash
   docker info | grep "Total Memory"
   ```

   - 16 GiB+ and 4+ CPUs available? You can proceed.
   - Anything lower: follow [configuration.md](./configuration.md) to raise Docker’s limits before running tests.

2. **Validate the containerized Gradle runtime**

   Fast sanity check that the image, wrapper, and permissions are ready—no database interaction required.

   ```bash
   WORKSPACE_DIR=$(pwd)
   docker run --rm \
     --name hibernate-ci-runner-check \
     -v "$WORKSPACE_DIR":/workspace \
     -w /workspace \
    eclipse-temurin:25-jdk \
     bash -lc './gradlew --version && ./gradlew tasks --group verification'
   ```

   - `WORKSPACE_DIR` is the absolute path to your `hibernate-orm` checkout; exporting it avoids path issues when directories contain spaces or are symlinked.
- `./gradlew --version` confirms the wrapper can launch on JDK 25.
   - `./gradlew tasks --group verification` lists verification targets without executing them; see [../local-setup.md](../local-setup.md) for a broader project walkthrough.

3. **Drop into an interactive container shell**

   Helpful when you need to inspect Gradle configuration, run ad-hoc commands, or clean up artifacts without launching the full suite.

   ```bash
   docker run --rm -it \
     --name hibernate-ci-runner-shell \
     --memory=16g \
     --cpus=6 \
     --network container:mysql \
     -e RDBMS=mysql_8_0 \
     -e GRADLE_OPTS="-Xmx6g -XX:MaxMetaspaceSize=1g" \
     -v "$PWD":/workspace \
     -w /workspace \
    eclipse-temurin:25-jdk \
     bash
   ```

   - From the shell you can run `./gradlew tasks`, inspect cached dependencies, or clean `tmp/` before re-running tests.
   - Exit with `Ctrl+D` or run `exit`. The container stops and Docker removes it automatically because of the `--rm` flag.

4. **Run the full suite or targeted profiles**
   - Ready for a non-interactive build? Use the balanced and high-headroom commands in [configuration.md](./configuration.md#runtime-profiles).
   - For filtered or iterative runs, follow the targeted examples in [configuration.md](./configuration.md#targeted-or-iterative-runs). Add `| tee tmp/run-$(date +%Y%m%d-%H%M%S).log` and inspect live output with `tail -f tmp/run-*.log` when you need a historical record.

5. **Monitor as needed**
   - Spot check with `docker stats hibernate-ci-runner --no-stream`.
   - Spin up the Prometheus + Grafana dashboards described in [monitoring/README.md](./monitoring/README.md) for longer runs.

## Host JDK Alternative

Helps when you need the tightest feedback loop or want to attach an IDE debugger.

1. Install JDK 25 and export `JAVA_HOME`.

   ```bash
   export JAVA_HOME=/path/to/jdk-25
   export PATH="$JAVA_HOME/bin:$PATH"
   export GRADLE_OPTS="-Xmx4g -XX:MaxMetaspaceSize=1g"
   java -version  # should report 25.x
   ```

2. Run the same build script directly:

   ```bash
   cd /path/to/hibernate-orm
   RDBMS=mysql_8_0 ./ci/build.sh
   ```

3. Switch back to the containerized workflow if:
   - Your workspace path contains spaces (macOS iCloud Drive paths break ShrinkWrap tests).
   - You need to guarantee parity with production CI.

## Where to Go Next

- [configuration.md](./configuration.md) – Docker sizing, runtime profiles, targeted execution, troubleshooting, and cleanup.
- [monitoring/README.md](./monitoring/README.md) – simple metrics vs. full Prometheus + Grafana dashboards for long-running suites.

## Troubleshooting

- **Tests feel slow:** Check `docker stats hibernate-ci-runner --no-stream`—expect 200–400% CPU. If lower, increase Docker CPUs or switch to the high-headroom profile.
- **Container exits immediately:** Inspect `docker ps -a | grep hibernate-ci-runner`. Exit 125 → missing volume/network; exit 1 → verify `./ci/build.sh` and working directory; exit 137 → raise `--memory` or lower `GRADLE_OPTS`.
- **OOM after resizing Docker:** Re-run `docker info | grep "Total Memory"` to confirm the new limit, then reduce Gradle heap (`-Xmx6g`) or limit workers (`--max-workers=2`).
