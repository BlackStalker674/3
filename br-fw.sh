#!/bin/bash
# =============================================================================
# br-fw.sh — автоматическая настройка стенда (ALT Linux p10/p11)
# Идемпотентный: повторный запуск безопасен. Лог: /var/log/<имя>.log
# =============================================================================
set -Ee

SCRIPT_NAME="br-fw.sh"
LOG_FILE="/var/log/${SCRIPT_NAME%.sh}.log"
BACKUP_DIR="/var/backups/${SCRIPT_NAME%.sh}"
DOMAIN="demo.prof"
PASS='P@ssw0rd'

# --- проверка прав -----------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "[ОШИБКА] ${SCRIPT_NAME}: запускайте от root" >&2
    exit 1
fi

mkdir -p /var/log "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'rc=$?; echo "[ОШИБКА] ${SCRIPT_NAME}: строка ${LINENO}, команда: ${BASH_COMMAND} (код ${rc})" >&2' ERR

export LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive

log()  { echo "[$(date '+%F %T')] $*"; }
warn() { echo "[$(date '+%F %T')] [WARN] $*" >&2; }
die()  { echo "[$(date '+%F %T')] [FATAL] $*" >&2; exit 1; }

log "===== Старт ${SCRIPT_NAME} ====="

# --- файлы -------------------------------------------------------------------
# write_file <путь> [режим] < stdin : записывает файл только если содержимое изменилось
write_file() {
    local f="$1" mode="${2:-644}" t
    mkdir -p "$(dirname "$f")"
    t=$(mktemp)
    cat > "$t"
    if [ -f "$f" ] && cmp -s "$t" "$f"; then
        rm -f "$t"
    else
        if [ -f "$f" ]; then
            cp -a "$f" "$BACKUP_DIR/$(echo "$f" | tr '/' '_').$(date +%s)" 2>/dev/null || true
        fi
        mv "$t" "$f"
        log "обновлён файл $f"
    fi
    chmod "$mode" "$f"
}

# ensure_line <файл> <строка> : добавить строку, если её нет
ensure_line() {
    touch "$1"
    if ! grep -qxF -- "$2" "$1"; then
        echo "$2" >> "$1"
    fi
}

# ensure_hosts <ip> <fqdn> <short>
ensure_hosts() {
    touch /etc/hosts
    sed -i "/[[:space:]]$2\([[:space:]]\|\$\)/d" /etc/hosts
    echo "$1 $2 $3" >> /etc/hosts
}

set_hostname() { # <fqdn> <ip>
    hostnamectl set-hostname "$1" 2>/dev/null || hostname "$1"
    ensure_line /etc/hosts "127.0.0.1 localhost"
    ensure_hosts "$2" "$1" "${1%%.*}"
}

# --- пакеты ------------------------------------------------------------------
APT_UPDATED=0
apt_update() {
    if [ "$APT_UPDATED" -eq 1 ]; then return 0; fi
    local i
    for i in 1 2 3; do
        if apt-get update; then APT_UPDATED=1; return 0; fi
        sleep 3
    done
    warn "apt-get update не удался (продолжаем с локальным кэшем)"
    return 0
}

pkg() { # установить все перечисленные пакеты (фатально при неудаче)
    local missing=() p i
    for p in "$@"; do
        if ! rpm -q "$p" >/dev/null 2>&1; then missing+=("$p"); fi
    done
    if [ "${#missing[@]}" -eq 0 ]; then return 0; fi
    apt_update
    for i in 1 2 3; do
        if apt-get install -y "${missing[@]}"; then return 0; fi
        sleep 3
    done
    die "Не удалось установить пакеты: ${missing[*]}"
}

pkg_try() { # установить пакет, неудача не фатальна
    if rpm -q "$1" >/dev/null 2>&1; then return 0; fi
    apt_update
    if apt-get install -y "$1"; then return 0; fi
    warn "пакет $1 не установлен"
    return 1
}

pkg_any() { # установить первый доступный из списка
    local p
    for p in "$@"; do
        if rpm -q "$p" >/dev/null 2>&1; then return 0; fi
    done
    apt_update
    for p in "$@"; do
        if apt-get install -y "$p"; then return 0; fi
    done
    return 1
}

pkg_find() { # pkg_find <regex> -> самое новое имя пакета
    apt-cache search "$1" 2>/dev/null | awk '{print $1}' | sort -V | tail -1
}

# --- службы ------------------------------------------------------------------
svc_exists() { systemctl cat "$1.service" >/dev/null 2>&1; }
svc_enable() { systemctl enable "$1" >/dev/null 2>&1 || true; systemctl restart "$1"; }
svc_first()  { local s; for s in "$@"; do if svc_exists "$s"; then echo "$s"; return 0; fi; done; return 1; }

# --- sshd --------------------------------------------------------------------
SSHD_CFG=/etc/openssh/sshd_config
sshd_set() { # <ключ> <значение>
    [ -f "$SSHD_CFG" ] || die "нет $SSHD_CFG"
    sed -i -E "/^[[:space:]]*#?[[:space:]]*$1[[:space:]]/d" "$SSHD_CFG"
    sed -i "1i $1 $2" "$SSHD_CFG"
}
sshd_ports() { # <порт> [порт...]
    [ -f "$SSHD_CFG" ] || die "нет $SSHD_CFG"
    sed -i -E "/^[[:space:]]*#?[[:space:]]*Port[[:space:]]/d" "$SSHD_CFG"
    local p
    for p in "$@"; do sed -i "1i Port $p" "$SSHD_CFG"; done
}
sshd_reload() {
    sshd -t || die "sshd_config содержит ошибки"
    svc_enable "$(svc_first sshd ssh)"
}

# --- сеть (etcnet ALT Linux) -------------------------------------------------
iface_exists() { [ -d "/sys/class/net/$1" ]; }

detect_iface() { # <желаемое имя> : если нет — первый физический интерфейс
    local want="$1" n
    if iface_exists "$want"; then echo "$want"; return 0; fi
    for n in /sys/class/net/*; do
        n="${n##*/}"
        case "$n" in lo|docker*|veth*|br-*|virbr*|tun*|tap*|gre*|sit*|bond*|dummy*) continue ;; esac
        warn "интерфейс $want не найден, используем $n"
        echo "$n"; return 0
    done
    echo "$want"
}

net_hash() { find /etc/net/ifaces -type f -exec md5sum {} + 2>/dev/null | sort -k2 | md5sum; }

net_options() { # <iface> [static|dhcp]
    write_file "/etc/net/ifaces/$1/options" <<EOF
TYPE=eth
BOOTPROTO=${2:-static}
DISABLED=no
NM_CONTROLLED=no
ONBOOT=yes
CONFIG_IPV4=yes
EOF
}

net_addr() { # <iface> <ip/mask> [ещё ip/mask...]
    local i="$1"; shift
    printf '%s\n' "$@" | write_file "/etc/net/ifaces/$i/ipv4address"
}

net_routes() { # <iface> <строка маршрута> [...]  напр. "default via 10.0.0.1"
    local i="$1"; shift
    printf '%s\n' "$@" | write_file "/etc/net/ifaces/$i/ipv4route"
}

net_vlan() { # <iface.vid> <родитель> <vid>
    write_file "/etc/net/ifaces/$1/options" <<EOF
TYPE=vlan
HOST=$2
VID=$3
DISABLED=no
ONBOOT=yes
CONFIG_IPV4=yes
EOF
}

nm_off() {
    if svc_exists NetworkManager; then
        systemctl disable --now NetworkManager >/dev/null 2>&1 || true
    fi
}

net_apply() { # <хэш до изменений>
    local after; after=$(net_hash)
    if [ "$1" != "$after" ]; then
        log "Конфигурация сети изменилась — перезапуск службы network"
        nm_off
        systemctl enable network >/dev/null 2>&1 || true
        systemctl restart network || warn "network restart вернул ошибку"
        sleep 4
    else
        log "Конфигурация сети без изменений"
    fi
}

enable_forward() {
    mkdir -p /etc/net /etc/sysctl.d
    touch /etc/net/sysctl.conf
    if grep -q '^net.ipv4.ip_forward' /etc/net/sysctl.conf; then
        sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
    else
        echo 'net.ipv4.ip_forward = 1' >> /etc/net/sysctl.conf
    fi
    echo 'net.ipv4.ip_forward = 1' | write_file /etc/sysctl.d/99-forward.conf
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

wait_ip() { # <iface> [сек]
    local i t="${2:-40}"
    for ((i=0; i<t; i++)); do
        if ip -4 addr show dev "$1" 2>/dev/null | grep -q 'inet '; then return 0; fi
        sleep 1
    done
    warn "интерфейс $1 не получил IPv4 за ${t}с"
    return 0
}

# --- iptables ----------------------------------------------------------------
ipt_add() { # <таблица> <цепочка> <правило...>  (идемпотентно)
    local t="$1"; shift
    if ! iptables -t "$t" -C "$@" 2>/dev/null; then iptables -t "$t" -A "$@"; fi
}
ipt_save() {
    pkg iptables
    mkdir -p /etc/sysconfig
    iptables-save > /etc/sysconfig/iptables
    systemctl enable iptables >/dev/null 2>&1 || true
}

# --- GRE + IPsec + OSPF ------------------------------------------------------
setup_gre() { # <iface> <local> <remote> <ip/mask> <родитель>
    modprobe ip_gre 2>/dev/null || true
    ensure_line /etc/modules ip_gre
    write_file "/etc/net/ifaces/$1/options" <<EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=$2
TUNREMOTE=$3
TUNOPTIONS='ttl 64'
HOST=$5
DISABLED=no
ONBOOT=yes
EOF
    net_addr "$1" "$4"
}

setup_ipsec() { # <local> <remote>  — transport-режим для защиты GRE
    pkg strongswan
    local cdir=/etc/strongswan
    if [ ! -d "$cdir" ]; then cdir=/etc; fi
    write_file "$cdir/ipsec.conf" <<EOF
config setup
    uniqueids=no
    charondebug="ike 1, knl 1, cfg 0"

conn gre-transport
    type=transport
    keyexchange=ikev2
    authby=secret
    left=$1
    right=$2
    leftprotoport=gre
    rightprotoport=gre
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256!
    ikelifetime=8h
    lifetime=1h
    dpdaction=restart
    auto=start
EOF
    # Кавычки вокруг пароля ОБЯЗАТЕЛЬНО экранируются:
    echo ": PSK \"P@ssw0rd\"" > /etc/ipsec.secrets
    chmod 600 /etc/ipsec.secrets
    if [ "$cdir" != "/etc" ]; then
        echo ": PSK \"P@ssw0rd\"" > "$cdir/ipsec.secrets"
        chmod 600 "$cdir/ipsec.secrets"
    fi
    local s
    s=$(svc_first ipsec strongswan strongswan-starter strongswan-swanctl) || die "служба strongSwan не найдена"
    svc_enable "$s"
    sleep 3
    ipsec statusall 2>/dev/null | head -n 20 || true
}

frr_apply() { # конфиг frr.conf из stdin
    pkg frr
    if grep -q '^ospfd=' /etc/frr/daemons; then
        sed -i 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons
    else
        echo 'ospfd=yes' >> /etc/frr/daemons
    fi
    write_file /etc/frr/frr.conf 640
    chown frr:frr /etc/frr/frr.conf 2>/dev/null || true
    svc_enable frr
    sleep 3
    vtysh -c 'show ip ospf neighbor' 2>/dev/null || true
}


chrony_client() { # клиент времени: источник — ISP (stratum 4)
    pkg_try chrony || return 0
    write_file /etc/chrony.conf <<'EOT'
server 172.16.1.1 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOT
    svc_enable "$(svc_first chronyd chrony)"
}

add_master() { # локальный администратор master, UID 2222, sudo без пароля
    pkg sudo
    local uid=2222 cur
    if ! id master >/dev/null 2>&1; then
        if getent passwd "$uid" >/dev/null; then
            die "UID $uid уже занят пользователем $(getent passwd "$uid" | cut -d: -f1)"
        fi
        useradd -m -u "$uid" -s /bin/bash -G wheel master
    else
        cur=$(id -u master)
        if [ "$cur" != "$uid" ]; then
            if getent passwd "$uid" >/dev/null; then
                warn "UID $uid занят — UID пользователя master остаётся $cur"
            else
                usermod -u "$uid" master
                chown -R "$uid" /home/master 2>/dev/null || true
            fi
        fi
        usermod -aG wheel master
    fi
    echo "master:$PASS" | chpasswd
    echo "master ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/master
    chmod 440 /etc/sudoers.d/master
    visudo -cf /etc/sudoers.d/master >/dev/null
    log "master: $(id master)"
}

WAN_IF=enp7s1; LAN_IF=enp7s2; VLAN_IF=enp7s2.20

# ---------------------------------------------------------------- 1. Сеть ----
set_hostname br-fw.$DOMAIN 127.0.1.1
NET_BEFORE=$(net_hash)
net_options "$WAN_IF"; net_addr "$WAN_IF" 192.168.1.2/30; net_routes "$WAN_IF" "default via 192.168.1.1"
net_options "$LAN_IF"; net_addr "$LAN_IF" 192.168.0.1/29
net_vlan "$VLAN_IF" "$LAN_IF" 20; net_addr "$VLAN_IF" 192.168.1.17/28
enable_forward
net_apply "$NET_BEFORE"

# ---------------------------------------------------------------- 2. DHCP ----
pkg dnsmasq
write_file /etc/dnsmasq.conf <<EOF
# DHCP для VLAN 20 (DNS-сервер dnsmasq отключён: port=0)
port=0
interface=$VLAN_IF
bind-interfaces
dhcp-authoritative
domain=$DOMAIN
dhcp-range=192.168.1.18,192.168.1.30,255.255.255.240,12h
dhcp-option=option:router,192.168.1.17
dhcp-option=option:dns-server,192.168.100.2
dhcp-option=option:domain-search,$DOMAIN
dhcp-leasefile=/var/lib/dnsmasq/dnsmasq.leases
EOF
mkdir -p /var/lib/dnsmasq
svc_enable dnsmasq

# --------------------------------------------------------------- 3. nftables -
pkg nftables
write_file /etc/nftables/nftables.nft <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    # порты, нужные клиентам для работы с контроллером домена (br-srv)
    set ad_tcp { type inet_service; flags interval; elements = { 53, 88, 135, 139, 389, 445, 464, 636, 3268, 3269, 49152-65535 } }
    set ad_udp { type inet_service; elements = { 53, 88, 123, 137, 138, 389, 464 } }

    chain input {
        type filter hook input priority 0; policy drop;
        iifname "lo" accept
        ct state established,related accept
        ct state invalid drop
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        tcp dport 22 accept
        ip protocol ospf accept
        udp dport 67 accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
        ct state invalid drop
        ip protocol icmp accept
        # LAN (enp7s2) и VLAN 20 (enp7s2.20) -> куда угодно
        iifname { "enp7s2", "enp7s2.20" } accept
        # входящие из внешней сети в LAN: DNAT-сервисы и AD
        iifname "enp7s1" oifname "enp7s2" tcp dport { 22, 80, 443, 2222, 8080 } accept
        iifname "enp7s1" oifname "enp7s2" tcp dport @ad_tcp accept
        iifname "enp7s1" oifname "enp7s2" udp dport @ad_udp accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        # NAT только для внешнего трафика, внутренние сети видят реальные адреса
        oifname "enp7s1" ip daddr != { 192.168.0.0/16, 10.10.10.0/30 } masquerade
    }
}
EOF
nft -c -f /etc/nftables/nftables.nft || die "nftables: ошибка в правилах"
svc_enable nftables
nft -f /etc/nftables/nftables.nft
log "nftables загружен"

# ------------------------------------------------------------ 4. OSPF --------
frr_apply <<'EOF'
frr defaults traditional
hostname br-fw
log syslog informational
no ipv6 forwarding
!
router ospf
 ospf router-id 3.3.3.3
 passive-interface default
 no passive-interface enp7s1
 network 192.168.1.0/30 area 0
 network 192.168.0.0/29 area 0
 network 192.168.1.16/28 area 0
exit
!
EOF

pkg openssh-server
sshd_reload

chrony_client

echo "=== br-fw.sh configured successfully ==="
