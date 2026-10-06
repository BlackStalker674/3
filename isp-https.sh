#!/bin/bash
# ISP, модуль 3, п.2: перенастройка обратного прокси nginx на https (ГОСТ-сертификаты из /root)
apt-get update && apt-get install -y openssl-gost-engine
control openssl-gost enabled

mkdir -p /etc/nginx/ssl
cp /root/web.au-team.irpo.{key,cer} /root/docker.au-team.irpo.{key,cer} /etc/nginx/ssl/
chmod 600 /etc/nginx/ssl/*.key

cat > /etc/nginx/sites-available.d/default.conf <<'EOF'
# http -> https
server {
	listen 80;
	server_name web.au-team.irpo docker.au-team.irpo;
	return 301 https://$host$request_uri;
}

server {
	listen 443 ssl;
	server_name web.au-team.irpo;
	ssl_certificate     /etc/nginx/ssl/web.au-team.irpo.cer;
	ssl_certificate_key /etc/nginx/ssl/web.au-team.irpo.key;
	ssl_protocols TLSv1.2;
	ssl_ciphers GOST2012-GOST8912-GOST8912:GOST2001-GOST89-GOST89:HIGH:!aNULL;
	ssl_prefer_server_ciphers on;

	location / {
		auth_basic "Restricted area";
		auth_basic_user_file /etc/nginx/.htpasswd;
		proxy_pass http://172.16.1.2:8080;
		proxy_set_header Host $host;
		proxy_set_header X-Real-IP $remote_addr;
		proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto $scheme;
	}
}

server {
	listen 443 ssl;
	server_name docker.au-team.irpo;
	ssl_certificate     /etc/nginx/ssl/docker.au-team.irpo.cer;
	ssl_certificate_key /etc/nginx/ssl/docker.au-team.irpo.key;
	ssl_protocols TLSv1.2;
	ssl_ciphers GOST2012-GOST8912-GOST8912:GOST2001-GOST89-GOST89:HIGH:!aNULL;
	ssl_prefer_server_ciphers on;

	location / {
		proxy_pass http://172.16.2.2:8080;
		proxy_set_header Host $host;
		proxy_set_header X-Real-IP $remote_addr;
		proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto $scheme;
	}
}
EOF

nginx -t && systemctl restart nginx
