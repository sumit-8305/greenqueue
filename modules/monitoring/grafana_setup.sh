#!/bin/bash
set -euo pipefail

dnf install -y docker
systemctl enable --now docker

# Clean up a previous RPM-based install if it was partially installed.
if systemctl list-unit-files grafana-server.service --no-legend 2>/dev/null | grep -q grafana-server; then
  systemctl disable --now grafana-server || true
fi

mkdir -p /opt/greenqueue/grafana/provisioning/datasources /opt/greenqueue/grafana/provisioning/dashboards /opt/greenqueue/grafana/dashboards
cat > /opt/greenqueue/grafana/provisioning/datasources/greenqueue-prometheus.yaml <<'EOF'
apiVersion: 1
datasources:
  - name: GreenQueue Prometheus
    uid: greenqueue-prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: true
EOF

cat > /opt/greenqueue/grafana/provisioning/dashboards/greenqueue.yaml <<'EOF'
apiVersion: 1
providers:
  - name: GreenQueue
    orgId: 1
    folder: GreenQueue
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
EOF

install -m 0644 /opt/greenqueue/greenqueue-dashboard.json /opt/greenqueue/grafana/dashboards/greenqueue-overview.json

docker pull grafana/grafana-oss:11.5.2
docker rm -f greenqueue-grafana 2>/dev/null || true
docker volume create greenqueue-grafana-data
docker run -d \
  --name greenqueue-grafana \
  --restart unless-stopped \
  --network host \
  -e GF_SERVER_HTTP_ADDR=127.0.0.1 \
  -e GF_SERVER_HTTP_PORT=3000 \
  -e GF_SECURITY_ADMIN_USER=admin \
  -e GF_SECURITY_ADMIN_PASSWORD=admin \
  -e GF_USERS_ALLOW_SIGN_UP=false \
  -v greenqueue-grafana-data:/var/lib/grafana \
  -v /opt/greenqueue/grafana/provisioning:/etc/grafana/provisioning:ro \
  -v /opt/greenqueue/grafana/dashboards:/var/lib/grafana/dashboards:ro \
  grafana/grafana-oss:11.5.2
