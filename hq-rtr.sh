#!/bin/bash
# =============================================================================
# hq-rtr.sh — автоматическая настройка стенда (ALT Linux p10/p11)
# Запуск: MODULE=1|2|3|all ./hq-rtr.sh   (по умолчанию all). Идемпотентен.
# Переменные: TZ_NAME (Asia/Krasnoyarsk), IFACE, DUMP_SQL, USERS_CSV, ...
# =============================================================================
set -Eeuo pipefail

SCRIPT_NAME="hq-rtr.sh"
LOG_FILE="/var/log/${SCRIPT_NAME%.sh}.log"
BACKUP_DIR="/var/backups/${SCRIPT_NAME%.sh}"
DOMAIN="demo.prof"
PASS='P@ssword'
MODULE="${MODULE:-all}"
TZ_NAME="${TZ_NAME:-Asia/Krasnoyarsk}"

if [ "$(id -u)" -ne 0 ]; then
    echo "[ОШИБКА] ${SCRIPT_NAME}: запускайте от root" >&2
    exit 1
fi
case "$MODULE" in 1|2|3|all) ;; *) echo "MODULE должен быть 1, 2, 3 или all" >&2; exit 1 ;; esac

mkdir -p /var/log "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'rc=$?; echo "[ОШИБКА] ${SCRIPT_NAME}: строка ${LINENO}, команда: ${BASH_COMMAND} (код ${rc})" >&2' ERR

export LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive

log()  { echo "[$(date '+%F %T')] $*"; }
warn() { echo "[$(date '+%F %T')] [WARN] $*" >&2; }
die()  { echo "[$(date '+%F %T')] [FATAL] $*" >&2; exit 1; }
want() { [ "$MODULE" = "all" ] || [ "$MODULE" = "$1" ]; }

log "===== Старт ${SCRIPT_NAME} (MODULE=${MODULE}) ====="

# --- файлы -------------------------------------------------------------------
write_file() { # <путь> [режим] < stdin : пишет только при изменении содержимого
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

ensure_line() { # <файл> <строка>
    touch "$1"
    if ! grep -qxF -- "$2" "$1"; then echo "$2" >> "$1"; fi
}

ensure_hosts() { # <ip> <fqdn> <short>
    touch /etc/hosts
    sed -i "/[[:space:]]$2\([[:space:]]\|\$\)/d" /etc/hosts
    echo "$1 $2 $3" >> /etc/hosts
}

set_hostname() { # <fqdn> <ip>
    hostnamectl set-hostname "$1" 2>/dev/null || hostname "$1"
    ensure_line /etc/hosts "127.0.0.1 localhost"
    ensure_hosts "$2" "$1" "${1%%.*}"
}

set_tz() {
    if command -v timedatectl >/dev/null 2>&1 && timedatectl set-timezone "$TZ_NAME" 2>/dev/null; then
        log "часовой пояс: $TZ_NAME"
    elif [ -f "/usr/share/zoneinfo/$TZ_NAME" ]; then
        ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
        log "часовой пояс (symlink): $TZ_NAME"
    else
        warn "часовой пояс $TZ_NAME не найден"
    fi
}

# --- пакеты ------------------------------------------------------------------
APT_UPDATED=0
ensure_dns() { # резервный публичный DNS, если имена не резолвятся
    local i
    for i in 1 2 3 4 5; do
        if getent hosts ftp.altlinux.org >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    if ! grep -q '77.88.8.7' /etc/resolv.conf 2>/dev/null; then
        echo 'nameserver 77.88.8.7' >> /etc/resolv.conf
        log "DNS: добавлен резервный сервер 77.88.8.7"
    fi
    return 0
}
apt_update() {
    if [ "$APT_UPDATED" -eq 1 ]; then return 0; fi
    ensure_dns
    local i
    for i in 1 2 3; do
        if apt-get update; then APT_UPDATED=1; return 0; fi
        sleep 3
    done
    warn "apt-get update не удался (продолжаем с локальным кэшем)"
    return 0
}
pkg() { # установить пакеты (фатально при неудаче)
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
pkg_try() { # нефатально
    if rpm -q "$1" >/dev/null 2>&1; then return 0; fi
    apt_update
    if apt-get install -y "$1"; then return 0; fi
    warn "пакет $1 не установлен"
    return 1
}
pkg_any() { # первый доступный из списка
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
pkg_find() { # <regex> -> самое новое имя пакета
    apt-cache search "$1" 2>/dev/null | awk '{print $1}' | sort -V | tail -n 1 || true
}

# --- службы ------------------------------------------------------------------
svc_exists() { systemctl cat "$1.service" >/dev/null 2>&1; }
svc_enable() {
    if [ -z "${1:-}" ]; then die "svc_enable: имя службы пустое (служба не найдена)"; fi
    systemctl enable "$1" >/dev/null 2>&1 || true
    systemctl restart "$1"
}
svc_first() { local s; for s in "$@"; do if svc_exists "$s"; then echo "$s"; return 0; fi; done; return 1; }

# --- sshd --------------------------------------------------------------------
SSHD_CFG=/etc/openssh/sshd_config
sshd_set() { # <ключ> <значение>
    [ -f "$SSHD_CFG" ] || die "нет $SSHD_CFG"
    sed -i -E "/^[[:space:]]*#?[[:space:]]*$1[[:space:]]/d" "$SSHD_CFG"
    sed -i "1i $1 $2" "$SSHD_CFG"
}
sshd_ports() {
    [ -f "$SSHD_CFG" ] || die "нет $SSHD_CFG"
    sed -i -E "/^[[:space:]]*#?[[:space:]]*Port[[:space:]]/d" "$SSHD_CFG"
    local p
    for p in "$@"; do sed -i "1i Port $p" "$SSHD_CFG"; done
}
sshd_reload() {
    local t out
    mkdir -p /etc/openssh
    for t in rsa ecdsa ed25519; do
        if [ ! -f "/etc/openssh/ssh_host_${t}_key" ]; then
            log "генерация хост-ключа SSH: $t"
            ssh-keygen -q -t "$t" -N '' -f "/etc/openssh/ssh_host_${t}_key"
        fi
    done
    chmod 600 /etc/openssh/ssh_host_*_key 2>/dev/null || true
    if ! out=$(sshd -t 2>&1); then die "sshd_config содержит ошибки: $out"; fi
    svc_enable "$(svc_first sshd ssh)"
}
ssh_setup() { # <порт...> : порт + баннер
    pkg openssh-server
    write_file /etc/openssh/banner <<'EOT'
Authorized access only
EOT
    sshd_ports "$@"
    sshd_set Banner /etc/openssh/banner
    sshd_reload
}
ssh_server_hardening() { # <порт> <пользователь> : для серверов
    ssh_setup "$1"
    sshd_set PasswordAuthentication yes
    sshd_set MaxAuthTries 2
    sshd_set AllowUsers "$2"
    sshd_reload
}

# --- пользователи ------------------------------------------------------------
add_admin() { # <user> [uid] — sudo без пароля
    pkg sudo
    local u="$1" uid="${2:-}" cur
    if ! id "$u" >/dev/null 2>&1; then
        if [ -n "$uid" ] && getent passwd "$uid" >/dev/null; then
            die "UID $uid уже занят пользователем $(getent passwd "$uid" | cut -d: -f1)"
        fi
        if [ -n "$uid" ]; then
            useradd -m -u "$uid" -s /bin/bash -G wheel "$u"
        else
            useradd -m -s /bin/bash -G wheel "$u"
        fi
    else
        if [ -n "$uid" ]; then
            cur=$(id -u "$u")
            if [ "$cur" != "$uid" ]; then
                if getent passwd "$uid" >/dev/null; then
                    warn "UID $uid занят — UID пользователя $u остаётся $cur"
                else
                    usermod -u "$uid" "$u"
                    chown -R "$uid" "/home/$u" 2>/dev/null || true
                fi
            fi
        fi
        usermod -aG wheel "$u"
    fi
    echo "$u:$PASS" | chpasswd
    echo "$u ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$u"
    chmod 440 "/etc/sudoers.d/$u"
    visudo -cf "/etc/sudoers.d/$u" >/dev/null
    log "администратор: $(id "$u")"
}

# --- сеть (etcnet ALT Linux) -------------------------------------------------
iface_exists() { [ -d "/sys/class/net/$1" ]; }
detect_iface() { # <желаемое имя>
    local want_if="$1" n
    if iface_exists "$want_if"; then echo "$want_if"; return 0; fi
    for n in /sys/class/net/*; do
        n="${n##*/}"
        case "$n" in lo|docker*|veth*|br-*|virbr*|tun*|tap*|gre*|sit*|bond*|dummy*) continue ;; esac
        warn "интерфейс $want_if не найден, используем $n"
        echo "$n"; return 0
    done
    echo "$want_if"
}
net_hash() { { find /etc/net/ifaces -type f -exec md5sum {} + 2>/dev/null || true; } | sort -k2 | md5sum; }
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
net_addr()   { local i="$1"; shift; printf '%s\n' "$@" | write_file "/etc/net/ifaces/$i/ipv4address"; }
net_routes() { local i="$1"; shift; printf '%s\n' "$@" | write_file "/etc/net/ifaces/$i/ipv4route"; }
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
nm_off() { if svc_exists NetworkManager; then systemctl disable --now NetworkManager >/dev/null 2>&1 || true; fi; }
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
require_ifaces() { # <if...> : интерфейсы существуют (/sys/class/net) и не пересекаются
    local i dups avail
    if [ "${SKIP_IFACE_CHECK:-0}" = "1" ]; then warn "проверка интерфейсов пропущена (SKIP_IFACE_CHECK=1)"; return 0; fi
    for i in "$@"; do
        if ! iface_exists "$i"; then
            avail=$(ls /sys/class/net 2>/dev/null | tr '\n' ' ' || true)
            die "интерфейс $i не найден в /sys/class/net/ (есть: $avail). Для обхода: SKIP_IFACE_CHECK=1"
        fi
    done
    dups=$(printf '%s\n' "$@" | sort | uniq -d)
    if [ -n "$dups" ]; then die "интерфейсы пересекаются: $dups"; fi
    log "интерфейсы подтверждены: $*"
}
wait_ip() { # <iface> [сек]
    local i t="${2:-40}" out
    for ((i=0; i<t; i++)); do
        out=$(ip -4 -o addr show dev "$1" 2>/dev/null || true)
        if [ -n "$out" ]; then return 0; fi
        sleep 1
    done
    warn "интерфейс $1 не получил IPv4 за ${t}с"
    return 0
}

# --- iptables ----------------------------------------------------------------
ipt_ready() { if ! command -v iptables >/dev/null 2>&1; then pkg iptables; fi; }
ipt_add() { # <таблица> <цепочка> <правило...> (идемпотентно)
    ipt_ready
    local t="$1"; shift
    if ! iptables -t "$t" -C "$@" 2>/dev/null; then iptables -t "$t" -A "$@"; fi
}
ipt_save() {
    pkg iptables
    mkdir -p /etc/sysconfig
    iptables-save > /etc/sysconfig/iptables
    systemctl enable iptables >/dev/null 2>&1 || true
}

# --- GRE / IPsec / OSPF ------------------------------------------------------
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
setup_ipsec() { # <local> <remote> — transport-режим защищает GRE
    pkg strongswan
    local cdir=/etc/strongswan s
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
    echo ": PSK \"P@ssword\"" > /etc/ipsec.secrets
    chmod 600 /etc/ipsec.secrets
    if [ "$cdir" != "/etc" ]; then
        echo ": PSK \"P@ssword\"" > "$cdir/ipsec.secrets"
        chmod 600 "$cdir/ipsec.secrets"
    fi
    s=$(svc_first ipsec strongswan strongswan-starter strongswan-swanctl) || die "служба strongSwan не найдена"
    svc_enable "$s"
    sleep 3
    ipsec statusall 2>/dev/null | sed -n '1,20p' || true
}
frr_apply() { # frr.conf из stdin
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
}
tun_bounce() { # переподнятие туннеля после включения IPsec
    if ip link show "$1" >/dev/null 2>&1; then
        if ip link set "$1" down && ip link set "$1" up; then
            log "туннель $1 переподнят"
        else
            warn "не удалось переподнять $1"
        fi
        sleep 3
    else
        warn "интерфейс $1 не найден — переподнятие пропущено"
    fi
}
wait_ospf() { # ждём соседа в состоянии Full; при неудаче перезапускаем frr один раз
    local i out tries=0
    while [ "$tries" -lt 2 ]; do
        for i in $(seq 1 30); do
            out=$(vtysh -c 'show ip ospf neighbor' 2>/dev/null || true)
            if [[ "$out" == *Full* ]]; then log "OSPF: соседство Full"; return 0; fi
            sleep 2
        done
        warn "OSPF-сосед не поднялся — перезапуск frr"
        systemctl restart frr || true
        tries=$((tries + 1))
    done
    warn "OSPF-сосед так и не перешёл в Full (проверьте противоположный роутер)"
    return 0
}

# --- время / логи ------------------------------------------------------------
chrony_client() { # клиент времени: источник — ISP
    pkg_try chrony || return 0
    write_file /etc/chrony.conf <<'EOT'
server 172.16.1.1 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOT
    svc_enable "$(svc_first chronyd chrony)"
}
rsyslog_client() { # пересылка логов (warning и выше) на hq-srv
    if ! pkg_any rsyslog rsyslog-classic; then warn "rsyslog не установлен — пересылка логов пропущена"; return 0; fi
    write_file /etc/rsyslog.d/forward.conf <<'EOT'
*.warning @@192.168.100.2:514
EOT
    svc_enable "$(svc_first rsyslog rsyslogd)"
}

# --- Additional.iso ----------------------------------------------------------
mount_extra() {
    local d
    if [ -d /mnt/additional ] && [ -n "$(ls -A /mnt/additional 2>/dev/null || true)" ]; then return 0; fi
    mkdir -p /mnt/additional
    for d in /dev/sr0 /dev/sr1 /dev/cdrom; do
        if [ -b "$d" ] && mount -o ro "$d" /mnt/additional 2>/dev/null; then
            log "Additional.iso смонтирован из $d"
            return 0
        fi
    done
    return 0
}
find_extra() { # <f|d> <имя/шаблон> -> путь (код 1, если не найдено)
    local t="$1" n="$2" r res
    mount_extra
    for r in /mnt/additional /media /root /opt /home /mnt/cdrom; do
        if [ -d "$r" ]; then
            res=$(find "$r" -maxdepth 4 -type "$t" -name "$n" 2>/dev/null | sed -n '1p' || true)
            if [ -n "$res" ]; then echo "$res"; return 0; fi
        fi
    done
    return 1
}

# --- файрвол роутеров в сторону ISP (модуль 3) --------------------------------
fw_router_wan() { # <wan-iface>
    local w="$1"
    ipt_add filter INPUT -i "$w" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ipt_add filter INPUT -i "$w" -p icmp -j ACCEPT
    ipt_add filter INPUT -i "$w" -p gre -j ACCEPT
    ipt_add filter INPUT -i "$w" -p esp -j ACCEPT
    ipt_add filter INPUT -i "$w" -p udp -m multiport --dports 500,4500 -j ACCEPT
    ipt_add filter INPUT -i "$w" -p tcp -m multiport --dports 22,80,443 -j ACCEPT
    ipt_add filter INPUT -i "$w" -p udp -m multiport --dports 53,123 -j ACCEPT
    ipt_add filter INPUT -i "$w" -j DROP
    ipt_add filter FORWARD -i "$w" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ipt_add filter FORWARD -i "$w" -p icmp -j ACCEPT
    ipt_add filter FORWARD -i "$w" -m conntrack --ctstate DNAT -j ACCEPT
    ipt_add filter FORWARD -i "$w" -j DROP
}


WAN_IF=enp7s1; TRUNK_IF=enp7s2          # WAN (ISP) / транк с VLAN (закреплено)
require_ifaces "$WAN_IF" "$TRUNK_IF"
# проброс портов: внешний порт -> порт сервера (согласовано с hq-srv.sh)
HQ_WEB_PORT="${HQ_WEB_PORT:-8080}"       # порт Apache на HQ-SRV (80 тоже слушается)
SSH_PORT_SRV="${SSH_PORT_SRV:-2222}"     # порт SSH на HQ-SRV
EXT_WEB_PORT=8080; EXT_SSH_PORT=2222

# =============================== МОДУЛЬ 1 ====================================
if want 1; then
    log "--- Модуль 1: сеть, VLAN, GRE, OSPF, DHCP, NAT, SSH ---"
    set_hostname hq-rtr.$DOMAIN 127.0.1.1
    set_tz
    NET_BEFORE=$(net_hash)

    net_options "$WAN_IF"
    net_addr    "$WAN_IF" 172.16.1.2/28
    net_routes  "$WAN_IF" "default via 172.16.1.1"

    # router-on-a-stick: транковый порт без адреса + VLAN-подинтерфейсы
    net_options "$TRUNK_IF"
    rm -f "/etc/net/ifaces/$TRUNK_IF/ipv4address" "/etc/net/ifaces/$TRUNK_IF/ipv4route"
    net_vlan "$TRUNK_IF.100" "$TRUNK_IF" 100; net_addr "$TRUNK_IF.100" 192.168.100.1/28
    net_vlan "$TRUNK_IF.200" "$TRUNK_IF" 200; net_addr "$TRUNK_IF.200" 192.168.200.1/28
    net_vlan "$TRUNK_IF.999" "$TRUNK_IF" 999; net_addr "$TRUNK_IF.999" 192.168.99.1/29

    # GRE-туннель до BR-RTR (10.10.10.0/30)
    setup_gre tun0 172.16.1.2 172.16.2.2 10.10.10.1/30 "$WAN_IF"
    enable_forward
    net_apply "$NET_BEFORE"

    # DHCP (dnsmasq) для VLAN 200: шлюз .1 исключён из пула
    pkg dnsmasq
    mkdir -p /var/lib/dnsmasq
    write_file /etc/dnsmasq.conf <<DNS
# DHCP для VLAN 200 (DNS-часть dnsmasq отключена: port=0)
port=0
interface=$TRUNK_IF.200
bind-interfaces
dhcp-authoritative
domain=$DOMAIN
dhcp-range=192.168.200.2,192.168.200.14,255.255.255.240,12h
dhcp-option=option:router,192.168.200.1
dhcp-option=option:dns-server,192.168.100.2
dhcp-option=option:domain-search,$DOMAIN
dhcp-leasefile=/var/lib/dnsmasq/dnsmasq.leases
DNS
    svc_enable dnsmasq

    # NAT наружу + фиксация TCP MSS (GRE/IPsec уменьшают MTU)
    ipt_add nat POSTROUTING -o "$WAN_IF" -j MASQUERADE
    ipt_add mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ipt_save

    # OSPF только на туннеле (локальные сети — passive), MD5-аутентификация
    frr_apply <<'FRR'
frr defaults traditional
hostname hq-rtr
log syslog informational
no ipv6 forwarding
!
interface tun0
 ip ospf network point-to-point
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssword
exit
!
router ospf
 ospf router-id 1.1.1.1
 passive-interface default
 no passive-interface tun0
 network 10.10.10.0/30 area 0
 network 192.168.100.0/28 area 0
 network 192.168.200.0/28 area 0
 network 192.168.99.0/29 area 0
exit
!
FRR

    add_admin admin
    ssh_setup 22
fi

# =============================== МОДУЛЬ 2 ====================================
if want 2; then
    log "--- Модуль 2: проброс портов, время ---"
    ipt_add nat PREROUTING -i "$WAN_IF" -p tcp --dport "$EXT_WEB_PORT" -j DNAT --to-destination "192.168.100.2:$HQ_WEB_PORT"
    ipt_add nat PREROUTING -i "$WAN_IF" -p tcp --dport "$EXT_SSH_PORT" -j DNAT --to-destination "192.168.100.2:$SSH_PORT_SRV"
    ipt_save
    chrony_client
fi

# =============================== МОДУЛЬ 3 ====================================
if want 3; then
    log "--- Модуль 3: IPsec поверх GRE, файрвол в сторону ISP, rsyslog ---"
    setup_ipsec 172.16.1.2 172.16.2.2
    tun_bounce tun0
    wait_ospf
    fw_router_wan "$WAN_IF"
    ipt_save
    rsyslog_client
fi

echo "=== hq-rtr.sh configured successfully ==="
