#!/bin/bash
# HQ-RTR
# tunnel.sh — замена базового GRE на шифрованный туннель WireGuard + восстановление OSPF
set -e

WG_IF="wg0"
WG_PORT="51820"
WG_LOCAL_TUN_IP="10.255.255.1/30"
WG_ENDPOINT_LOCAL="172.16.1.2"
WG_ENDPOINT_REMOTE="172.16.2.2"
WG_DIR="/etc/wireguard"

echo ">>> [1/6] Установка WireGuard"
apt-get update -y
apt-get install -y -q wireguard-tools

echo ">>> [2/6] Отключение старого GRE-туннеля (Модуль 1)"
ip link set gre1 down 2>/dev/null || true
if [ -d /etc/net/ifaces/gre1 ]; then
    sed -i 's/^DISABLED=no/DISABLED=yes/' /etc/net/ifaces/gre1/options 2>/dev/null || true
fi

echo ">>> [3/6] Генерация ключевой пары WireGuard"
mkdir -p "${WG_DIR}"
chmod 700 "${WG_DIR}"
if [ ! -f "${WG_DIR}/privatekey" ]; then
    wg genkey | tee "${WG_DIR}/privatekey" | wg pubkey > "${WG_DIR}/publickey"
    chmod 600 "${WG_DIR}/privatekey"
fi
LOCAL_PRIVKEY=$(cat "${WG_DIR}/privatekey")
LOCAL_PUBKEY=$(cat "${WG_DIR}/publickey")

echo "    Публичный ключ HQ-RTR (передать на BR-RTR): ${LOCAL_PUBKEY}"
echo "    >>> Сохраните этот ключ — он нужен в PeerPublicKey на BR-RTR <<<"

# Публичный ключ BR-RTR (заполняется после первого запуска tunnel.sh на BR-RTR)
REMOTE_PUBKEY_FILE="${WG_DIR}/br-rtr.pub"
if [ ! -f "${REMOTE_PUBKEY_FILE}" ]; then
    echo "REPLACE_WITH_BR_RTR_PUBLIC_KEY" > "${REMOTE_PUBKEY_FILE}"
    echo "    [ВНИМАНИЕ] Впишите публичный ключ BR-RTR в ${REMOTE_PUBKEY_FILE} и перезапустите скрипт"
fi
REMOTE_PUBKEY=$(cat "${REMOTE_PUBKEY_FILE}")

echo ">>> [4/6] Конфигурация интерфейса wg0"
cat > "${WG_DIR}/${WG_IF}.conf" <<EOF
[Interface]
PrivateKey = ${LOCAL_PRIVKEY}
Address = ${WG_LOCAL_TUN_IP}
ListenPort = ${WG_PORT}

[Peer]
PublicKey = ${REMOTE_PUBKEY}
Endpoint = ${WG_ENDPOINT_REMOTE}:${WG_PORT}
AllowedIPs = 10.255.255.0/30
PersistentKeepalive = 25
EOF
chmod 600 "${WG_DIR}/${WG_IF}.conf"

systemctl enable --now "wg-quick@${WG_IF}"
systemctl restart "wg-quick@${WG_IF}" 2>/dev/null || true

echo ">>> [5/6] Открытие UDP-порта WireGuard на внешнем интерфейсе"
iptables -C INPUT -p udp --dport ${WG_PORT} -j ACCEPT 2>/dev/null || \
iptables -A INPUT -p udp --dport ${WG_PORT} -j ACCEPT
iptables-save > /etc/sysconfig/iptables

echo ">>> [6/6] Восстановление OSPF поверх wg0 (FRR)"
cat >> /etc/frr/frr.conf <<EOF

interface ${WG_IF}
 ip ospf network point-to-point
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssword
EOF

# Сеть туннеля 10.255.255.0/30 уже объявлена в router ospf (Модуль 1) —
# добавляем только "no passive-interface" для нового интерфейса wg0
grep -q "no passive-interface ${WG_IF}" /etc/frr/frr.conf || \
    sed -i "/no passive-interface gre1/a\\ no passive-interface ${WG_IF}" /etc/frr/frr.conf

systemctl restart frr

echo "==================================================================="
echo " WireGuard-туннель HQ-RTR <-> BR-RTR настроен (${WG_LOCAL_TUN_IP})."
echo " Публичный ключ HQ-RTR: ${LOCAL_PUBKEY}"
echo " Убедитесь, что этот ключ прописан в конфиге BR-RTR и наоборот."
echo "==================================================================="
