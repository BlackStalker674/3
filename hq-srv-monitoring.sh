#!/bin/bash
# HQ-SRV, модуль 3, п.7: мониторинг Prometheus + node_exporter + Grafana (порт 3000)
# Нагрузка на ЦП, занятая ОП и основной накопитель; логин admin, пароль P@ssw0rd; доступ только с HQ-CLI
CLI_NET=192.168.200.0/28

apt-get update && apt-get install -y tzdata iptables grafana prometheus prometheus-node_exporter
# Если пакеты называются иначе: apt-cache search -n 'grafana|prometheus'

cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: hq-srv
    static_configs:
      - targets: ['localhost:9100']
EOF

# Источник данных и панель
mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
cat > /etc/grafana/provisioning/datasources/prometheus.yml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
EOF
cat > /etc/grafana/provisioning/dashboards/default.yml <<'EOF'
apiVersion: 1
providers:
  - name: default
    type: file
    options:
      path: /var/lib/grafana/dashboards
EOF
cat > /var/lib/grafana/dashboards/hq-srv.json <<'EOF'
{
  "title": "HQ-SRV",
  "uid": "hq-srv",
  "schemaVersion": 38,
  "refresh": "10s",
  "time": {"from": "now-30m", "to": "now"},
  "panels": [
    {"id": 1, "type": "timeseries", "title": "Нагрузка на ЦП, %", "datasource": "Prometheus",
     "gridPos": {"h": 8, "w": 8, "x": 0, "y": 0},
     "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100}, "overrides": []},
     "targets": [{"refId": "A", "expr": "100 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[1m])) * 100"}]},
    {"id": 2, "type": "timeseries", "title": "Занято ОП, %", "datasource": "Prometheus",
     "gridPos": {"h": 8, "w": 8, "x": 8, "y": 0},
     "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100}, "overrides": []},
     "targets": [{"refId": "A", "expr": "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100"}]},
    {"id": 3, "type": "timeseries", "title": "Занято на основном накопителе (/), %", "datasource": "Prometheus",
     "gridPos": {"h": 8, "w": 8, "x": 16, "y": 0},
     "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100}, "overrides": []},
     "targets": [{"refId": "A", "expr": "(1 - node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"}) * 100"}]}
  ]
}
EOF
chown -R grafana:grafana /var/lib/grafana/dashboards 2>/dev/null || true

# Логин и пароль
sed -i 's/^;\?admin_user *=.*/admin_user = admin/; s/^;\?admin_password *=.*/admin_password = P@ssw0rd/' /etc/grafana/grafana.ini

for s in prometheus-node_exporter node_exporter prometheus grafana-server grafana; do
  systemctl enable --now $s 2>/dev/null
  systemctl restart $s 2>/dev/null
done
sleep 5
grafana-cli admin reset-admin-password 'P@ssw0rd' 2>/dev/null || true

# Доступ к порту 3000 только из сети HQ-CLI (и локально)
iptables -D INPUT -p tcp --dport 3000 -j DROP 2>/dev/null
iptables -A INPUT -i lo -p tcp --dport 3000 -j ACCEPT
iptables -A INPUT -s $CLI_NET -p tcp --dport 3000 -j ACCEPT
iptables -A INPUT -p tcp --dport 3000 -j DROP
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables

ss -tlnp | grep -E '3000|9090|9100'
echo "Мониторинг: http://hq-srv.au-team.irpo:3000 (admin / P@ssw0rd), с HQ-CLI"
