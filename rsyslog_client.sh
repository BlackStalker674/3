#!/bin/bash
# HQ-RTR / BR-RTR / BR-SRV (выполнить на каждом из трёх узлов)
# rsyslog_client.sh — пересылка локальных логов на центральный сервер HQ-SRV
set -e

LOG_SERVER="10.10.10.2"

echo ">>> [1/2] Установка rsyslog (если ещё не установлен)"
apt-get update -y
apt-get install -y -q rsyslog

echo ">>> [2/2] Настройка пересылки на HQ-SRV (UDP 514)"
cat > /etc/rsyslog.d/forward-to-hqsrv.conf <<EOF
*.* @${LOG_SERVER}:514
EOF

systemctl enable --now rsyslog
systemctl restart rsyslog

echo "Пересылка логов на ${LOG_SERVER}:514 настроена."
