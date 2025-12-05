# Hibernate ORM Test Monitoring

Monitor containerized Hibernate ORM test runs with either lightweight CLI tools or a full Prometheus + Grafana stack.

## Choose Your Monitoring Path

### Simple: Docker Stats

- Best for quick health checks or when you only need live CPU and memory numbers.
- Works without any additional containers.
- Run during a test:

  ```bash
  docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
  ```

- Watch for `hibernate-ci-runner` memory creeping toward the Docker limit or CPU falling below expectations.

### Advanced: Prometheus + Grafana (Recommended for long runs)

- Provides historical trends, alerting-friendly metrics, and curated dashboards.
- Requires the local stack defined in this directory; follow the quick start below.

## Quick Start: Prometheus + Grafana Stack

1. **Provision the stack**

   ```bash
   cd docker-runtime/monitoring
   ./setup-monitoring.sh
   ```

   This launches:
   - **Prometheus** for metrics storage
   - **cAdvisor** for container metrics
   - **Grafana** with curated dashboards (IDs 893 and 179)

2. **Log in to Grafana**
   - URL: <http://localhost:3000>
   - Credentials: `admin` / `admin` (Grafana may prompt for a password change; optional)

3. **Open dashboards**
   - **Docker Container & Host Metrics (893)** – live container CPU, memory, disk, and network.
   - **Docker and System Monitoring (179)** – host-level capacity and Docker daemon status.
   - Navigate via ☰ → Dashboards once logged in.

4. **Know the other endpoints**
   - Prometheus: <http://localhost:9090> (use for PromQL queries/export)
   - cAdvisor: <http://localhost:8080> (raw container stats UI)

5. **Expected metrics while tests run**
   - Memory: 6–12 GB (peak under 18 GB when Docker is configured with 24 GB for the container)
   - CPU: 300–600% (indicates 3–6 active workers)
   - Restarts/OOMs: stay at 0

If dashboards report “No Data”, verify container health with `docker-compose ps` and see the troubleshooting section below.

## Pre-loaded Dashboards

### 1. Docker Container & Host Metrics (Dashboard ID: 893)

**Most popular cAdvisor dashboard** - 500K+ downloads

**Shows:**

- Real-time container CPU usage (per container)
- Memory usage with limits and percentages
- Network I/O (received/transmitted)
- Disk I/O (read/write operations)
- File system usage
- Container restart count

**Use for:**

- Monitoring `hibernate-ci-runner` resource consumption
- Identifying memory leaks (steadily increasing memory)
- Verifying parallel execution (high CPU %)
- Detecting OOM events before they happen

### 2. Docker and System Monitoring (Dashboard ID: 179)

**System-wide Docker metrics** - Production-grade monitoring

**Shows:**

- Container health status
- System-wide resource allocation
- Docker daemon metrics
- Container lifecycle events
- Resource quota enforcement

**Use for:**

- Overall system health check
- Comparing multiple test runs
- Understanding resource distribution across containers
- Capacity planning

## What to Watch During Test Execution

### Memory Pattern (Normal)

```
Start:  1-2 GB  (Gradle daemon starting)
Ramp:   2-6 GB  (Test workers spawning)
Peak:   6-12 GB (Full parallel execution)
End:    < 18 GB (Should never hit 24GB limit)
```

### CPU Pattern (Normal)

```
Single-threaded: 100%
Parallel (4 workers): 300-400%
Peak compilation: 600-800%
```

### Warning Signs

- ❌ Memory steadily climbing to 100%
- ❌ CPU stuck at < 150% (parallelism not working)
- ❌ Container restarts > 0
- ❌ OOM events > 0

## Manual Commands

### Start monitoring stack

```bash
docker-compose up -d
```

### View logs

```bash
docker-compose logs -f
```

### Stop monitoring (preserve data)

```bash
docker-compose stop
```

### Stop and remove all data

```bash
docker-compose down -v
```

### Check service health

```bash
docker-compose ps
```

## Troubleshooting

### Dashboard shows "No Data"

**Check Prometheus targets:**

```bash
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job, health}'
```

Should show:

```json
{"job": "cadvisor", "health": "up"}
{"job": "prometheus", "health": "up"}
```

**If cAdvisor is down on Apple Silicon:** use the simple path with `docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"` while investigating.

### Port conflicts

If ports 3000, 8080, or 9090 are in use, edit `docker-compose.yml`:

```yaml
ports:
  - "3001:3000"  # Change left side only
```

### Grafana won't start

Check logs:

```bash
docker logs grafana
```

Common fix - reset Grafana data:

```bash
docker-compose down -v
docker-compose up -d
```

## Exporting Metrics for Analysis

### Export memory usage data

```bash
curl -G 'http://localhost:9090/api/v1/query_range' \
  --data-urlencode 'query=container_memory_usage_bytes{name="hibernate-ci-runner"}' \
  --data-urlencode 'start=2024-01-01T00:00:00Z' \
  --data-urlencode 'end=2024-01-01T01:00:00Z' \
  --data-urlencode 'step=15s' | jq '.' > memory-usage.json
```

### Export CPU usage data

```bash
curl -G 'http://localhost:9090/api/v1/query_range' \
  --data-urlencode 'query=rate(container_cpu_usage_seconds_total{name="hibernate-ci-runner"}[5m])' \
  --data-urlencode 'start=2024-01-01T00:00:00Z' \
  --data-urlencode 'end=2024-01-01T01:00:00Z' \
  --data-urlencode 'step=15s' | jq '.' > cpu-usage.json
```

## Architecture

```text
┌──────────────────┐
│ hibernate-mysql- │
│   ci-runner      │◄────────┐
│  (test container)│         │
└──────────────────┘         │
                             │ metrics
┌──────────────────┐         │ (HTTP)
│    cAdvisor      │◄────────┘
│ (container stats)│
└─────────┬────────┘
          │ exposes
          │ metrics
          ▼
┌──────────────────┐
│   Prometheus     │
│ (time series DB) │
└─────────┬────────┘
          │ queries
          ▼
┌──────────────────┐
│     Grafana      │
│   (dashboards)   │
└──────────────────┘
```

## Files Structure

```text
docker-runtime/monitoring/
├── setup-monitoring.sh           # One-command setup script
├── docker-compose.yml            # Service definitions
├── prometheus.yml                # Prometheus config
├── provisioning/
│   ├── datasources/
│   │   └── prometheus.yml        # Auto-configure Prometheus datasource
│   └── dashboards/
│       ├── dashboards.yml        # Dashboard provider config
│       ├── cadvisor-dashboard.json       # Dashboard ID: 893
│       └── docker-monitoring-dashboard.json  # Dashboard ID: 179
└── README.md                     # This file
```

## Additional Resources

- **Dashboard 893**: <https://grafana.com/grafana/dashboards/893>
- **Dashboard 179**: <https://grafana.com/grafana/dashboards/179>
- **Prometheus Query Guide**: <https://prometheus.io/docs/prometheus/latest/querying/basics/>
- **Grafana Dashboard Best Practices**: <https://grafana.com/docs/grafana/latest/best-practices/>
