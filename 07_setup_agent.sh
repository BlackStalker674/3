#!/bin/bash
# HQ-SRV / BR-SRV (выполнить на каждом из двух узлов)
# 07_setup_agent.sh — установка и авто-регистрация агента мониторинга (CPU/RAM/Disk)
set -e

MONITOR_SRV="10.10.10.2"
HOSTNAME_TAG=$(hostname -s)

echo ">>> [1/4] Установка Zabbix Agent"
apt-get update -y
apt-get install -y -q zabbix-agent

echo ">>> [2/4] Определение имени systemd-юнита агента"
ZBX_UNIT=$(systemctl list-unit-files 2>/dev/null | grep -oE '^zabbix[a-z_-]*agent[a-z_-]*\.service' | head -n1)
if [ -z "$ZBX_UNIT" ]; then
    ZBX_UNIT=$(rpm -ql zabbix-agent 2>/dev/null | grep -E 'systemd/system/.*\.service$' | xargs -n1 basename | head -n1)
fi
ZBX_UNIT="${ZBX_UNIT:-zabbix_agentd}"
echo "    Юнит агента: ${ZBX_UNIT}"

echo ">>> [3/4] Настройка агента: сервер, авто-регистрация, сбор CPU/RAM/Disk"
sed -i \
    -e "s/^Server=.*/Server=${MONITOR_SRV}/" \
    -e "s/^ServerActive=.*/ServerActive=${MONITOR_SRV}/" \
    -e "s/^Hostname=.*/Hostname=${HOSTNAME_TAG}/" \
    /etc/zabbix/zabbix_agentd.conf

grep -q "^Server=${MONITOR_SRV}" /etc/zabbix/zabbix_agentd.conf || echo "Server=${MONITOR_SRV}" >> /etc/zabbix/zabbix_agentd.conf
grep -q "^ServerActive=${MONITOR_SRV}" /etc/zabbix/zabbix_agentd.conf || echo "ServerActive=${MONITOR_SRV}" >> /etc/zabbix/zabbix_agentd.conf
grep -q "^Hostname=${HOSTNAME_TAG}" /etc/zabbix/zabbix_agentd.conf || echo "Hostname=${HOSTNAME_TAG}" >> /etc/zabbix/zabbix_agentd.conf

# HostMetadata используется правилом авто-регистрации на сервере Zabbix
# (Configuration -> Actions -> Autoregistration actions), чтобы новый хост
# автоматически привязывался к шаблону "Template OS Linux by Zabbix agent",
# который уже включает элементы данных CPU/RAM/Disk "из коробки".
grep -q "^HostMetadata=" /etc/zabbix/zabbix_agentd.conf || \
    echo "HostMetadata=linux;auto-cpu-ram-disk" >> /etc/zabbix/zabbix_agentd.conf

echo ">>> [4/4] Запуск агента"
systemctl enable --now "${ZBX_UNIT}"
systemctl restart "${ZBX_UNIT}"

echo "==================================================================="
echo " Агент мониторинга ${HOSTNAME_TAG} настроен и отправляет метрики на ${MONITOR_SRV}."
echo " На сервере Zabbix проверьте правило автогегистрации и привязку шаблона"
echo " 'Template OS Linux by Zabbix agent' для сбора CPU/RAM/Disk."
echo "==================================================================="
