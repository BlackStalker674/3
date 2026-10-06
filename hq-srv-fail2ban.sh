#!/bin/bash
# HQ-SRV, модуль 3, п.9: защита ssh (порт 2026) от перебора: 3 попытки, бан на 1 минуту
apt-get update && apt-get install -y tzdata fail2ban python3-module-systemd

sed -i 's/before = paths-altlinux.conf/before = paths-altlinux-systemd.conf/' /etc/fail2ban/jail.conf

mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled  = true
port     = 2026
backend  = systemd
maxretry = 3
findtime = 10m
bantime  = 1m
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban
sleep 3
fail2ban-client status sshd
