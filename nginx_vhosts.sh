#!/bin/bash
# HQ-SRV
# nginx_vhosts.sh — виртуальные хосты web.au-team.irpo и docker.au-team.irpo (HTTP -> HTTPS)
set -e

CA_DIR="/etc/pki/au-team-ca"

echo ">>> [1/3] Установка Nginx"
apt-get update -y
apt-get install -y -q nginx

echo ">>> [2/3] Настройка сайтов"
mkdir -p /var/www/web.au-team.irpo /var/www/docker.au-team.irpo
echo "Welcome to AU-TEAM Web Service" > /var/www/web.au-team.irpo/index.html
echo "AU-TEAM Docker Registry Frontend" > /var/www/docker.au-team.irpo/index.html

cat > /etc/nginx/conf.d/web.au-team.irpo.conf <<EOF
server {
    listen 80;
    server_name web.au-team.irpo;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name web.au-team.irpo;

    ssl_certificate     ${CA_DIR}/certs/web.au-team.irpo.crt;
    ssl_certificate_key ${CA_DIR}/private/web.au-team.irpo.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/web.au-team.irpo;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

cat > /etc/nginx/conf.d/docker.au-team.irpo.conf <<EOF
server {
    listen 80;
    server_name docker.au-team.irpo;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name docker.au-team.irpo;

    ssl_certificate     ${CA_DIR}/certs/docker.au-team.irpo.crt;
    ssl_certificate_key ${CA_DIR}/private/docker.au-team.irpo.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/docker.au-team.irpo;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

echo ">>> [3/3] Проверка и запуск Nginx"
nginx -t
systemctl enable --now nginx
systemctl restart nginx

echo "Виртуальные хосты web.au-team.irpo и docker.au-team.irpo настроены."
