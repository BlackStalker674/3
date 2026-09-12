#!/bin/bash
# HQ-RTR
# firewall.sh — nftables на внешнем интерфейсе (в сторону ISP): разрешить только необходимое
set -e

WAN_IF="eth0"
WG_PORT="51820"          # WireGuard (Модуль 3, Задача 3)
GRE_PROTO="47"           # запасной вариант, если используется GRE вместо WireGuard

echo ">>> [1/3] Установка nftables"
apt-get update -y
apt-get install -y -q nftables

echo ">>> [2/3] Формирование набора правил"
cat > /etc/nftables/au-team-firewall.nft <<EOF
#!/usr/sbin/nft -f

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # Локальный трафик и уже установленные соединения
        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        # ICMP (диагностика)
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        # Служебные протоколы туннелирования HQ-RTR <-> BR-RTR
        iif "${WAN_IF}" udp dport ${WG_PORT} accept
        iif "${WAN_IF}" ip protocol ${GRE_PROTO} accept

        # Разрешённые сервисы со стороны ISP/Интернета
        iif "${WAN_IF}" tcp dport 80 accept
        iif "${WAN_IF}" tcp dport 443 accept
        iif "${WAN_IF}" udp dport 53 accept
        iif "${WAN_IF}" tcp dport 53 accept
        iif "${WAN_IF}" udp dport 123 accept

        # Остальной входящий трафик с внешнего интерфейса — сброс (policy drop)
    }

    chain forward {
        type filter hook forward priority 0; policy accept;
        # NAT/маршрутизация локальных сетей обрабатывается отдельно (Модуль 1, iptables NAT)
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF

echo ">>> [3/3] Применение и включение nftables"
nft -f /etc/nftables/au-team-firewall.nft
grep -q "au-team-firewall.nft" /etc/nftables.conf 2>/dev/null || \
    echo 'include "/etc/nftables/au-team-firewall.nft"' >> /etc/nftables.conf

systemctl enable --now nftables
systemctl restart nftables

echo "Правила nftables применены на ${WAN_IF} (HQ-RTR): разрешены только HTTP/HTTPS/DNS/NTP/ICMP/туннель."
