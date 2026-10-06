#!/bin/bash
# BR-RTR, модуль 3: п.3 шифрование туннеля (GRE поверх IPsec), п.4 межсетевой экран, п.6 rsyslog-клиент
LOCAL=172.16.2.2
REMOTE=172.16.1.2
WAN=enp7s1
LOGSRV=192.168.100.2
PSK='P@ssw0rd'

apt-get update && apt-get install -y tzdata strongswan iptables rsyslog

# ---------- п.3: IPsec в транспортном режиме защищает GRE (tun0 и OSPF остаются прежними) ----------
CONF=/etc/strongswan; [ -d $CONF ] || CONF=/etc
cat > $CONF/ipsec.conf <<EOF
config setup

conn gre-tunnel
    keyexchange=ikev2
    type=transport
    authby=secret
    left=$LOCAL
    right=$REMOTE
    leftprotoport=47
    rightprotoport=47
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256!
    auto=start
EOF
echo "$LOCAL $REMOTE : PSK \"$PSK\"" > $CONF/ipsec.secrets
chmod 600 $CONF/ipsec.secrets

systemctl enable --now ipsec 2>/dev/null || systemctl enable --now strongswan
systemctl restart ipsec 2>/dev/null || systemctl restart strongswan
sleep 5
ipsec statusall | head -20

# ---------- п.4: межсетевой экран со стороны ISP ----------
iptables -F INPUT
iptables -F FORWARD
iptables -t mangle -F FORWARD

# INPUT: сам роутер
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT ! -i $WAN -j ACCEPT
iptables -A INPUT -i $WAN -p gre -j ACCEPT
iptables -A INPUT -i $WAN -p esp -j ACCEPT
iptables -A INPUT -i $WAN -p udp -m multiport --dports 500,4500 -j ACCEPT
iptables -A INPUT -i $WAN -p icmp -j ACCEPT
iptables -A INPUT -i $WAN -j DROP

# FORWARD: из Интернета во внутреннюю сеть
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i $WAN -m conntrack --ctstate DNAT -j ACCEPT
iptables -A FORWARD -i $WAN -p tcp -m multiport --dports 80,443 -j ACCEPT
iptables -A FORWARD -i $WAN -p tcp --dport 53 -j ACCEPT
iptables -A FORWARD -i $WAN -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -i $WAN -p udp --dport 123 -j ACCEPT
iptables -A FORWARD -i $WAN -p icmp -j ACCEPT
iptables -A FORWARD -i $WAN -j DROP

# Туннель добавляет заголовки: подгоняем MSS
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables

# ---------- OSPF должен возобновить работу после перенастройки туннеля ----------
systemctl restart frr
sleep 10
vtysh -c 'show ip ospf neighbor'

# ---------- п.6: логи (warning и выше) на HQ-SRV ----------
cat > /etc/rsyslog.d/remote.conf <<EOF
global(localHostname="br-rtr")
*.warning action(type="omfwd" target="$LOGSRV" port="514" protocol="tcp")
EOF
systemctl enable --now rsyslog
systemctl restart rsyslog
logger -p user.warning "test warning from br-rtr"
