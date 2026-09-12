#!/bin/bash
# HQ-CLI
# 05_cups_cli.sh — подключение сетевого PDF-принтера с HQ-SRV, назначение по умолчанию
set -e

PRINTER_NAME="AU-TEAM-PDF"
PRINTER_URI="ipp://hq-srv.au-team.irpo:631/printers/${PRINTER_NAME}"

echo ">>> [1/4] Установка клиента печати (CUPS-клиент)"
apt-get update -y
apt-get install -y -q cups-client cups-ipp-utils 2>/dev/null || apt-get install -y -q cups-client

echo ">>> [2/4] Проверка доступности сервера печати HQ-SRV"
lpstat -h hq-srv.au-team.irpo:631 -p 2>/dev/null || echo "[ПРЕДУПРЕЖДЕНИЕ] Сервер печати пока не отвечает — проверьте сеть/CUPS на HQ-SRV"

echo ">>> [3/4] Подключение сетевого принтера"
lpadmin -p "${PRINTER_NAME}" \
    -E \
    -v "${PRINTER_URI}" \
    -m everywhere

cupsenable "${PRINTER_NAME}"
cupsaccept "${PRINTER_NAME}"

echo ">>> [4/4] Назначение принтера по умолчанию"
lpoptions -d "${PRINTER_NAME}"

echo "==================================================================="
echo " Принтер по умолчанию: $(lpstat -d)"
echo " Проверка: echo 'test' | lp -d ${PRINTER_NAME}"
echo "==================================================================="
