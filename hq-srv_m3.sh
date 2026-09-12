#!/bin/bash
# HQ-SRV
# hq-srv_m3.sh — быстрый запуск/проверка стека мониторинга (Zabbix) + mon.au-team.irpo
set -e

ZBX_WEB_PORT="8080"
DNS_ZONE_FILE="/var/lib/bind/au-team.irpo.zone"

echo ">>> [1/4] Проверка/запуск стека мониторинга Zabbix (развёрнут в Модуле 2)"
if ! systemctl is-active --quiet zabbix-server; then
    apt-get update -y
    apt-get install -y -q zabbix-server-mysql zabbix-web-nginx-mysql
fi
systemctl enable --now zabbix-server
systemctl restart zabbix-server

echo ">>> [2/4] Виртуальный хост Nginx: mon.au-team.irpo -> Zabbix Web (${ZBX_WEB_PORT})"
cat > /etc/nginx/conf.d/mon.au-team.irpo.conf <<EOF
server {
    listen 80;
    server_name mon.au-team.irpo;

    location / {
        proxy_pass http://127.0.0.1:${ZBX_WEB_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

nginx -t
systemctl enable --now nginx
systemctl restart nginx

echo ">>> [3/4] Добавление DNS-записи mon.au-team.irpo в зону au-team.irpo"
if [ -f "${DNS_ZONE_FILE}" ]; then
    grep -q "^mon " "${DNS_ZONE_FILE}" || {
        echo "mon         IN  A   10.10.10.2" >> "${DNS_ZONE_FILE}"
        # Увеличиваем Serial (первое число перед "; Serial"), чтобы изменения
        # подхватились вторичными серверами
        awk '
            /; *Serial/ && !done {
                match($0, /[0-9]+/)
                n = substr($0, RSTART, RLENGTH) + 1
                sub(/[0-9]+/, n)
                done = 1
            }
            { print }
        ' "${DNS_ZONE_FILE}" > "${DNS_ZONE_FILE}.tmp" && mv "${DNS_ZONE_FILE}.tmp" "${DNS_ZONE_FILE}"
    }
    named-checkzone au-team.irpo "${DNS_ZONE_FILE}" && \
        systemctl reload bind 2>/dev/null || systemctl reload named
else
    echo "[ПРЕДУПРЕЖДЕНИЕ] Файл зоны ${DNS_ZONE_FILE} не найден — добавьте запись mon.au-team.irpo вручную"
fi

echo ">>> [4/4] Проверка доступности"
sleep 2
curl -s -o /dev/null -w "HTTP статус mon.au-team.irpo: %{http_code}\n" http://mon.au-team.irpo/ || true

echo "==================================================================="
echo " Веб-интерфейс мониторинга: http://mon.au-team.irpo"
echo "==================================================================="
