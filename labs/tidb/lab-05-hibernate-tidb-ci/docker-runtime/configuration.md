# Docker Runtime Configuration for Hibernate Testing

Configure your Docker runtime to run Hibernate ORM's full test suite without out-of-memory failures.

## Table of Contents

- [Quick Reference](#quick-reference-card)
- [Do I Need This?](#do-i-need-this)
- [Configuration Guide](#quick-configuration-guide)
  - [Colima](#for-colima)
  - [Docker Desktop](#for-docker-desktop)
- [Understanding Resources](#understanding-resource-requirements)
- [Runtime Profiles](#runtime-profiles)
- [Targeted or Iterative Runs](#targeted-or-iterative-runs)
- [Monitoring Options](#monitoring-options)
- [Runtime Troubleshooting](#runtime-troubleshooting)
- [Cleanup and Resource Management](#cleanup-and-resource-management)
- [Metrics for Analysis](#metrics-for-analysis)
- [Troubleshooting](#troubleshooting)
  - [Configuration Issues](#configuration-issues)
- [Reference](#reference-resource-calculation)

---

## Quick Reference Card

**Choose your configuration based on system RAM:**

| System RAM | Docker Memory | Docker CPUs | Container Memory | Test Duration |
|------------|---------------|-------------|------------------|---------------|
| **16 GB** | 10 GB | 4 | 8 GB | 60-90 min |
| **32 GB** | 20 GB | 6 | 16 GB | 35-45 min |
| **64 GB** | 32 GB | 8 | 24 GB | 25-35 min |
| **96 GB+** | 32-48 GB | 8-12 | 24-32 GB | 25-35 min |

**Quick diagnosis:** Run `docker info | grep "Total Memory"` - if less than 16GB, configure the Docker runtime first.

---

## Do I Need This?

**Run this quick check:**

```bash
docker info | grep "Total Memory"
```

**If the output shows less than 16GB**, you need to configure your Docker runtime before running the full test suite.

**Symptom:** Tests fail with exit code 137 (OOM killed) even though your system has plenty of RAM.

**Root cause:** Docker Desktop/Colima default to conservative limits (typically 4-6GB). Container `--memory` requests are silently capped at this limit.

---

## Quick Configuration Guide

### Step 1: Identify Your Docker Runtime

```bash
docker info | grep "Operating System"
```

- Shows "Colima" → Use [Colima Instructions](#for-colima)
- Shows "Docker Desktop" → Use [Docker Desktop Instructions](#for-docker-desktop)

### Step 2: Configure Resources

Choose your runtime below and follow the configuration steps.

---

## For Colima

### Configure Memory and CPU

**Stop Colima if running:**

```bash
colima stop
```

**Start with appropriate resources based on your system:**

| Your System | Command |
|-------------|---------|
| **16GB RAM** | `colima start --cpu 4 --memory 10 --disk 50` |
| **32GB RAM** | `colima start --cpu 6 --memory 20 --disk 80` |
| **64GB+ RAM** | `colima start --cpu 8 --memory 32 --disk 100` |
| **Mac Studio (96GB, 28 cores)** | `colima start --cpu 12 --memory 48 --disk 120` |

**Parameters:**
- `--cpu`: Number of CPU cores to allocate
- `--memory`: RAM in gigabytes
- `--disk`: Disk space in gigabytes

### Make Configuration Persistent

Create or edit `~/.colima/default/colima.yaml`:

```yaml
cpu: 8
memory: 32
disk: 100
```

Now `colima start` will always use these settings.

### Verify Configuration

```bash
colima status
docker info | grep -E "(Total Memory|CPUs)"
```

**✅ Expected output:**

```
CPUs: 8
Total Memory: 31.28GiB
```

**❌ If values don't match,** run `colima stop && colima delete` and start fresh with correct parameters.

---

## For Docker Desktop

### Configure Memory and CPU

1. **Open Docker Desktop Settings**
   - Click Docker icon in menu bar
   - Select **Settings** (or **Preferences**)
   - Navigate to **Resources** tab

2. **Set resources based on your system:**

| Your System RAM | Set Docker Memory | Set Docker CPUs |
|-----------------|-------------------|-----------------|
| 16 GB | 10 GB | 4 CPUs |
| 32 GB | 20 GB | 6 CPUs |
| 64 GB | 32 GB | 8 CPUs |
| 96 GB+ | 32-48 GB | 8-12 CPUs |

3. **Apply and restart**
   - Click **Apply & Restart**
   - Wait 30-60 seconds for Docker to restart

### Verify Configuration

```bash
docker info | grep -E "(Total Memory|CPUs)"
```

**✅ Expected output:**

```
CPUs: 8
Total Memory: 31.28GiB
```

**❌ If you see less than 16GB,** Docker didn't restart properly. Restart Docker Desktop manually.

---

## Understanding Resource Requirements

### Why These Numbers?

**Gradle test execution requires:**
- **Gradle daemon:** 4-8GB heap
- **Test workers:** 2-4 workers, each using 2-4GB
- **Peak memory:** 12-20GB during parallel execution
- **Recommended:** 32GB provides comfortable headroom

**CPU allocation:**
- More CPUs = more parallel test workers
- 8 CPUs optimal for full test suite
- 4 CPUs minimum (will limit parallelism)

### Expected Results

| Metric | Before Configuration | After Configuration |
|--------|---------------------|---------------------|
| Docker Memory | 5.7 GiB | 32 GiB |
| Docker CPUs | 4 | 8 |
| Test Duration | Fails at 8-13 min (OOM) | Completes in 25-35 min |
| Gradle Workers | 2 (limited) | 4 (optimal) |
| Exit Code | 137 (OOM killed) | 0 (success) |

---

## Runtime Profiles

Create a log directory once per checkout so test runs can write timestamped artifacts:

```bash
mkdir -p tmp
```

Both profiles assume the MySQL container is already running and commands are executed from the `hibernate-orm` repository root.

### Profile 1 — Balanced Throughput (matches CI)

```bash
docker run --rm \
  --name hibernate-ci-runner \
  --memory=16g \
  --cpus=6 \
  --network container:mysql \
  -e RDBMS=mysql_8_0 \
  -e GRADLE_OPTS="-Xmx6g -XX:MaxMetaspaceSize=1g" \
  -v "$PWD":/workspace \
  -w /workspace \
  eclipse-temurin:25-jdk \
  bash -lc 'RDBMS=mysql_8_0 ./ci/build.sh' 2>&1 | tee tmp/mysql-ci-balanced-$(date +%Y%m%d-%H%M%S).log
```

### Profile 2 — High Headroom (debugging & monitoring)

```bash
docker run --rm \
  --name hibernate-ci-runner \
  --memory=24g \
  --cpus=8 \
  --network container:mysql \
  -e RDBMS=mysql_8_0 \
  -e GRADLE_OPTS="-Xmx8g -XX:MaxMetaspaceSize=2g" \
  -v "$PWD":/workspace \
  -w /workspace \
  eclipse-temurin:25-jdk \
  bash -lc 'RDBMS=mysql_8_0 ./ci/build.sh' 2>&1 | tee tmp/mysql-ci-headroom-$(date +%Y%m%d-%H%M%S).log
```

Each run streams Gradle output to the console and archives it under `tmp/` for later comparison.

| Metric | Balanced (16g / 6 CPUs) | High headroom (24g / 8 CPUs) |
|--------|-------------------------|------------------------------|
| Duration | 16-20 minutes | 16-20 minutes |
| Peak Memory | ~10 GB (≈62% of limit) | ~10 GB (≈42% of limit) |
| Average Memory | ~7.8 GB | ~7.8 GB |
| Average CPU | 200-300% (2-3 cores busy) | 200-300% (2-3 cores busy) |
| Gradle Workers | 3 concurrent | 3-4 concurrent |
| OOM Events | 0 | 0 |

## Targeted or Iterative Runs

Use Gradle filtering when you only need a subset of tests:

```bash
docker run --rm \
  --name hibernate-ci-runner \
  --memory=12g \
  --cpus=4 \
  --network container:mysql \
  -e RDBMS=mysql_8_0 \
  -e GRADLE_OPTS="-Xmx4g -XX:MaxMetaspaceSize=768m" \
  -v "$PWD":/workspace \
  -w /workspace \
  eclipse-temurin:25-jdk \
  bash -lc 'RDBMS=mysql_8_0 ./ci/build.sh --tests org.hibernate.orm.test.SomeTestClass' \
  2>&1 | tee tmp/mysql-ci-targeted-$(date +%Y%m%d-%H%M%S).log
```

- Dial memory/CPU down for shorter runs, but keep at least 8 GB / 4 CPUs to avoid throttling JVM startup.
- Use Gradle’s `--tests`, `-PtestCategory=`, or `-DskipTests=` switches as needed.

## Monitoring Options

- **Quick health check:** `docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"` during a run. Expect 200-600% CPU and memory safely below the limit.
- **Full observability:** Follow [monitoring/README.md](./monitoring/README.md) to launch the Prometheus + Grafana stack with curated dashboards.

## Runtime Troubleshooting

### Tests run but are very slow
- Check CPU utilisation: `docker stats hibernate-ci-runner --no-stream` should report 200-400%.
- Verify Gradle worker count: `grep "Gradle Test Executor" tmp/mysql-ci-*.log | awk '{print $4}' | sort -u | wc -l` should return 3-4 workers.
- If throughput stays low, increase Docker CPUs to 8 and run the high-headroom profile.

### Container exits immediately
- Inspect exit codes: `docker ps -a | grep hibernate-ci-runner`.
- Review logs: `docker logs $(docker ps -a | grep hibernate-ci-runner | awk '{print $1}' | head -1)`.
- Common fixes:
  - Exit 125 → volume path or network missing; verify the repository path and `mysql` network.
  - Exit 1 → command failure; ensure `./ci/build.sh` exists and that you ran the command from the repo root.
  - Exit 137 → not enough memory; bump `--memory` to at least 8 GB or reduce `GRADLE_OPTS` to `-Xmx4g`.

### Still seeing OOM kills after configuring Docker
- Re-run `docker info | grep "Total Memory"` to confirm Docker applied the new limit.
- Watch the Grafana “Docker Container & Host Metrics” dashboard for spikes to 100% memory.
- Reduce Gradle heap (`-Xmx6g`) or limit parallelism with `--max-workers=2` if the container touches its memory ceiling.

## Cleanup and Resource Management

- **Stop the test container:** `docker stop hibernate-ci-runner` (no-op if `--rm` already removed it).
- **Tear down monitoring stack:** `cd docker-runtime/monitoring && docker-compose down` (or `stop` to retain Prometheus data).
- **Reclaim host resources:** lower Docker Desktop sliders or restart Colima with smaller `--cpu`/`--memory` values once testing finishes.
- **Purge run artifacts:** remove `tmp/mysql-ci-*.log` and `tmp/worker-stats.log` when you no longer need them; optionally run `./gradlew clean` to free Gradle cache space.

## Metrics for Analysis

With the monitoring stack running:
- Memory leak checks: Prometheus query `container_memory_usage_bytes{name="hibernate-ci-runner"}` should plateau near the end of the run.
- CPU saturation: `rate(container_cpu_usage_seconds_total{name="hibernate-ci-runner"}[5m])` highlights under-utilised cores.
- OOM detection: `container_oom_events_total{name="hibernate-ci-runner"}` must stay at `0`.

Export samples for offline analysis with:

```bash
curl -G 'http://localhost:9090/api/v1/query_range' \
  --data-urlencode 'query=container_memory_usage_bytes{name="hibernate-ci-runner"}' \
  --data-urlencode 'start=2024-01-01T00:00:00Z' \
  --data-urlencode 'end=2024-01-01T01:00:00Z' \
  --data-urlencode 'step=15s' | jq '.' > tmp/memory-usage.json
```

Adjust the time window to match your test execution.

## Troubleshooting

### Configuration Issues

Issues during Docker/Colima setup and verification.

#### Docker Limit Not Increased After Configuration

**Problem:** Tests fail with OOM even after configuration.

**Diagnosis steps:**

**1. Verify Docker actually restarted:**

```bash
docker info | grep "Total Memory"
```

Should show your configured value (e.g., 32GiB). If not, restart Docker Desktop or Colima.

**2. Check container memory limit:**

While tests are running:

```bash
docker stats hibernate-ci-runner --no-stream
```

Look at the `LIMIT` column. Should match your `--memory` setting.

**3. Review monitoring stack:**

Open Grafana dashboard and check:
- **Memory usage graph:** Does it spike to 100% before failure?
- **OOM events:** Dashboard shows count of OOM kills
- **Worker count:** Should see 3-5 Java processes

**4. Analyze test logs:**

```bash
grep -i "out of memory\|OOM\|exit.*137" tmp/mysql-ci-*.log
```

**Solutions:**

**If memory spikes to limit:**
- Increase container memory: `--memory=32g`
- Reduce Gradle heap: `-Xmx6g` instead of `-Xmx8g`
- Limit parallelism: Add `--max-workers=2` to Gradle command

**If Docker limit not increased:**
- Restart Docker Desktop completely
- For Colima: `colima stop && colima delete && colima start --cpu 8 --memory 32 --disk 100`

---

## Common Pitfalls

### Pitfall 1: Assuming Container Memory Works Without Docker Limit

**Wrong assumption:** "I requested `--memory=24g`, so my container has 24GB."

**Reality:** Docker silently caps at its configured limit. If Docker has 6GB total, container gets 6GB max.

**Solution:** Always verify Docker limit first with `docker info | grep "Total Memory"`.

### Pitfall 2: Not Restarting Docker After Configuration

**Wrong assumption:** "I changed settings in Docker Desktop, it should work now."

**Reality:** Settings don't apply until Docker restarts.

**Solution:** Always click "Apply & Restart" and wait for restart to complete. Verify with `docker info`.

### Pitfall 3: Over-allocating Docker Memory

**Wrong assumption:** "More is better, I'll give Docker all 96GB of my RAM."

**Reality:** macOS/host OS needs memory too. Over-allocation causes system instability.

**Solution:** Leave 30-50% of system RAM for host OS. For 96GB system, allocate 32-48GB to Docker.

### Pitfall 4: Ignoring CPU Allocation

**Wrong assumption:** "Memory is the only bottleneck."

**Reality:** Gradle parallel execution needs multiple CPUs. With 2 CPUs, only 2 test workers can run.

**Solution:** Allocate at least 6-8 CPUs for optimal parallel test execution.

---

## Reference: Resource Calculation

### How Memory is Allocated

**Understanding the memory breakdown:**

| Component | Memory Required | Notes |
|-----------|----------------|-------|
| Gradle Daemon | 8 GB | JVM heap for build orchestration |
| Test Worker 1 | 4 GB | First parallel test executor |
| Test Worker 2 | 4 GB | Second parallel test executor |
| Test Worker 3 | 4 GB | Third parallel test executor |
| Test Worker 4 | 4 GB | Fourth parallel test executor |
| OS Overhead | 4 GB | System buffers, Docker overhead |
| **Total Needed** | **28 GB** | **Round to 32GB for safety** |

**Container gets 75% of Docker allocation:**
- Docker configured: 32 GB
- Container allocation: 24 GB (32 × 0.75)
- Reserve 25% for Docker overhead and other containers

### Minimum vs Optimal Configurations

| Configuration | Docker Memory | Docker CPUs | Container Memory | Workers | Duration |
|---------------|---------------|-------------|------------------|---------|----------|
| Minimum | 10 GB | 4 | 8 GB | 2 | 60-90 min |
| Recommended | 20 GB | 6 | 16 GB | 3 | 35-45 min |
| Optimal | 32 GB | 8 | 24 GB | 4 | 25-35 min |

---

## Additional Resources

### Official Documentation

- [Docker Desktop Resource Limits](https://docs.docker.com/desktop/settings/mac/#resources)
- [Colima Configuration](https://github.com/abiosoft/colima/blob/main/docs/CONFIGURATION.md)
- [Gradle Worker Configuration](https://docs.gradle.org/current/userguide/build_environment.html#sec:configuring_jvm_memory)

### Monitoring Tools

- **Prometheus:** https://prometheus.io/docs/introduction/overview/
- **Grafana:** https://grafana.com/docs/grafana/latest/getting-started/
- **cAdvisor:** https://github.com/google/cadvisor
- **OpenTelemetry:** https://opentelemetry.io/docs/

### Related Guides

- [Local Setup Guide](../local-setup.md) - Initial Hibernate ORM setup
- [MySQL CI Guide](../mysql-ci.md) - Running MySQL tests
- [TiDB CI Guide](../tidb-ci.md) - Running TiDB tests
