#!/bin/bash
set -e

echo "Setting up Hibernate ORM Test Monitoring Stack..."
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "✓ Creating directory structure..."
mkdir -p provisioning/datasources
mkdir -p provisioning/dashboards

echo "✓ Downloading popular Grafana dashboards..."

if [ ! -f "provisioning/dashboards/cadvisor-dashboard.json" ]; then
    echo "  - Docker Container & Host Metrics (Dashboard ID: 893)"
    curl -s https://grafana.com/api/dashboards/893/revisions/latest/download -o provisioning/dashboards/cadvisor-dashboard.json
fi

if [ ! -f "provisioning/dashboards/docker-monitoring-dashboard.json" ]; then
    echo "  - Docker and System Monitoring (Dashboard ID: 179)"
    curl -s https://grafana.com/api/dashboards/179/revisions/latest/download -o provisioning/dashboards/docker-monitoring-dashboard.json
fi

echo "✓ Fixing datasource references..."
sed -i.bak 's/"datasource": "${DS_PROMETHEUS}"/"datasource": "Prometheus"/g' provisioning/dashboards/cadvisor-dashboard.json 2>/dev/null || sed -i '' 's/"datasource": "${DS_PROMETHEUS}"/"datasource": "Prometheus"/g' provisioning/dashboards/cadvisor-dashboard.json
sed -i.bak 's/"datasource": "${DS_PROMETHEUS}"/"datasource": "Prometheus"/g' provisioning/dashboards/docker-monitoring-dashboard.json 2>/dev/null || sed -i '' 's/"datasource": "${DS_PROMETHEUS}"/"datasource": "Prometheus"/g' provisioning/dashboards/docker-monitoring-dashboard.json
rm -f provisioning/dashboards/*.bak

echo "✓ Dashboards ready"
echo ""
echo "Starting monitoring stack..."
docker-compose up -d

echo ""
echo "Waiting for services to be ready..."
sleep 5

echo ""
echo "======================================"
echo "Monitoring Stack Ready!"
echo "======================================"
echo ""
echo "Access your dashboards:"
echo "  Grafana:    http://localhost:3000 (admin/admin)"
echo "  Prometheus: http://localhost:9090"
echo "  cAdvisor:   http://localhost:8080"
echo ""
echo "Pre-loaded Grafana Dashboards:"
echo "  1. Docker Container & Host Metrics"
echo "     - Real-time container resource usage"
echo "     - Memory, CPU, Network, Disk I/O"
echo "     - Historical trends and graphs"
echo ""
echo "  2. Docker and System Monitoring"
echo "     - System-wide Docker metrics"
echo "     - Container health and status"
echo "     - Resource allocation overview"
echo ""
echo "To stop: cd monitoring && docker-compose down"
echo "======================================"
