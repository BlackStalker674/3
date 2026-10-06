#!/bin/bash
# BR-SRV, модуль 3, п.6: отправка логов (warning и выше) на HQ-SRV
apt-get update && apt-get install -y tzdata rsyslog

cat > /etc/rsyslog.d/remote.conf <<'EOF'
global(localHostname="br-srv")
*.warning action(type="omfwd" target="192.168.100.2" port="514" protocol="tcp")
EOF

systemctl enable --now rsyslog
systemctl restart rsyslog
logger -p user.warning "test warning from br-srv"
