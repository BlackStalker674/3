#!/bin/bash
# =============================================================================
# hq-srv.sh — автоматическая настройка стенда (ALT Linux p10/p11)
# Запуск: MODULE=1|2|3|all ./hq-srv.sh   (по умолчанию all). Идемпотентен.
# Переменные: TZ_NAME (Asia/Krasnoyarsk), IFACE, DUMP_SQL, USERS_CSV, ...
# =============================================================================
set -Eeuo pipefail

SCRIPT_NAME="hq-srv.sh"
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


IFACE=$(detect_iface "${IFACE:-enp7s1}")
log "Рабочий интерфейс: $IFACE"
SSH_PORT_SRV="${SSH_PORT_SRV:-2222}"     # порт SSH на HQ-SRV (согласовано с hq-rtr.sh)
HQ_WEB_PORT="${HQ_WEB_PORT:-8080}"       # дополнительный порт Apache (80 слушается всегда)
RESOLV_TXT=$(printf 'search %s\noptions timeout:1 attempts:2\nnameserver 127.0.0.1\nnameserver 77.88.8.7\n' "$DOMAIN")

# =============================== МОДУЛЬ 1 ====================================
if want 1; then
    log "--- Модуль 1: сеть, учётная запись, SSH, DNS ---"
    set_hostname hq-srv.$DOMAIN 192.168.100.2
    set_tz
    NET_BEFORE=$(net_hash)
    net_options "$IFACE"
    net_addr    "$IFACE" 192.168.100.2/28
    net_routes  "$IFACE" "default via 192.168.100.1"
    printf '%s\n' "$RESOLV_TXT" | write_file "/etc/net/ifaces/$IFACE/resolv.conf"
    net_apply "$NET_BEFORE"
    printf '%s\n' "$RESOLV_TXT" > /etc/resolv.conf 2>/dev/null || true

    add_admin user 2222
    ssh_server_hardening "$SSH_PORT_SRV" user

    # ------------------------------ DNS (BIND) ------------------------------
    pkg bind bind-utils
    BIND_CONF=/etc/bind/named.conf
    if [ ! -f "$BIND_CONF" ]; then BIND_CONF=/var/lib/bind/etc/named.conf; fi
    [ -f "$BIND_CONF" ] || die "не найден named.conf"
    BIND_DIR=$(dirname "$BIND_CONF")
    ZDIR="$BIND_DIR/zone"
    mkdir -p "$ZDIR"
    SERIAL="$(date +%Y%m%d)01"

    write_file "$BIND_DIR/options.conf" <<'NAMED'
options {
	version "unknown";
	directory "/etc/bind/zone";
	pid-file none;
	listen-on { any; };
	listen-on-v6 { none; };
	forwarders { 77.88.8.7; 77.88.8.3; };
	allow-query { any; };
	allow-recursion { 127.0.0.1; 192.168.0.0/16; 10.0.0.0/8; 172.16.0.0/12; };
	recursion yes;
	dnssec-validation no;
};
NAMED

    write_file "$BIND_DIR/local.conf" <<'NAMED'
zone "demo.prof" { type master; file "demo.prof"; allow-update { none; }; };
zone "100.168.192.in-addr.arpa" { type master; file "100.168.192.in-addr.arpa"; };
zone "200.168.192.in-addr.arpa" { type master; file "200.168.192.in-addr.arpa"; };
zone "0.168.192.in-addr.arpa"   { type master; file "0.168.192.in-addr.arpa"; };
zone "1.168.192.in-addr.arpa"   { type master; file "1.168.192.in-addr.arpa"; };
zone "99.168.192.in-addr.arpa"  { type master; file "99.168.192.in-addr.arpa"; };
NAMED

    SRV_T="br-srv.demo.prof."
    write_file "$ZDIR/demo.prof" <<ZONE
\$TTL 1h
@   IN SOA hq-srv.demo.prof. admin.demo.prof. ( $SERIAL 1h 15m 1w 1h )
@   IN NS  hq-srv.demo.prof.
@   IN A   192.168.0.2
isp     IN A 172.16.1.1
hq-rtr  IN A 192.168.100.1
hq-srv  IN A 192.168.100.2
hq-cli  IN A 192.168.200.2
br-rtr  IN A 192.168.1.1
br-fw   IN A 192.168.1.2
br-srv  IN A 192.168.0.2
web     IN A 172.16.1.1
docker  IN A 172.16.1.1
mon     IN A 192.168.100.2
; --- SRV-записи Active Directory (контроллер домена — br-srv) ---
_ldap._tcp                                  IN SRV 0 100 389  $SRV_T
_kerberos._tcp                              IN SRV 0 100 88   $SRV_T
_kerberos._udp                              IN SRV 0 100 88   $SRV_T
_kpasswd._tcp                               IN SRV 0 100 464  $SRV_T
_kpasswd._udp                               IN SRV 0 100 464  $SRV_T
_gc._tcp                                    IN SRV 0 100 3268 $SRV_T
_ldap._tcp.dc._msdcs                        IN SRV 0 100 389  $SRV_T
_ldap._tcp.pdc._msdcs                       IN SRV 0 100 389  $SRV_T
_kerberos._tcp.dc._msdcs                    IN SRV 0 100 88   $SRV_T
_ldap._tcp.Default-First-Site-Name._sites   IN SRV 0 100 389  $SRV_T
_kerberos._tcp.Default-First-Site-Name._sites IN SRV 0 100 88 $SRV_T
_ldap._tcp.Default-First-Site-Name._sites.dc._msdcs IN SRV 0 100 389 $SRV_T
_kerberos._tcp.Default-First-Site-Name._sites.dc._msdcs IN SRV 0 100 88 $SRV_T
ZONE

    mk_rev() { # <файл> ; записи PTR из stdin
        {
            printf '$TTL 1h\n'
            printf '@ IN SOA hq-srv.demo.prof. admin.demo.prof. ( %s 1h 15m 1w 1h )\n' "$SERIAL"
            printf '@ IN NS hq-srv.demo.prof.\n'
            cat
        } | write_file "$ZDIR/$1"
    }
    mk_rev 100.168.192.in-addr.arpa <<'PTR'
1 IN PTR hq-rtr.demo.prof.
2 IN PTR hq-srv.demo.prof.
PTR
    mk_rev 200.168.192.in-addr.arpa <<'PTR'
1 IN PTR hq-rtr.demo.prof.
2 IN PTR hq-cli.demo.prof.
PTR
    mk_rev 0.168.192.in-addr.arpa <<'PTR'
1 IN PTR br-fw.demo.prof.
2 IN PTR br-srv.demo.prof.
PTR
    mk_rev 1.168.192.in-addr.arpa <<'PTR'
1 IN PTR br-rtr.demo.prof.
2 IN PTR br-fw.demo.prof.
PTR
    mk_rev 99.168.192.in-addr.arpa <<'PTR'
1 IN PTR hq-rtr.demo.prof.
PTR

    # named.conf обязан подключать options.conf и local.conf
    ensure_include() { # <имя файла>
        local name="$1"
        if grep -Eq "^[[:space:]]*include[[:space:]]+\"[^\"]*/?${name}\"" "$BIND_CONF"; then return 0; fi
        cp -a "$BIND_CONF" "$BACKUP_DIR/named.conf.$(date +%s)"
        if grep -Eq "^[[:space:]]*(//|#)[[:space:]]*include[[:space:]]+\"[^\"]*/?${name}\"" "$BIND_CONF"; then
            sed -i -E "s#^[[:space:]]*(//|\#)[[:space:]]*(include[[:space:]]+\"[^\"]*/?${name}\")#\2#" "$BIND_CONF"
            log "named.conf: раскомментирован include $name"
        else
            echo "include \"/etc/bind/${name}\";" >> "$BIND_CONF"
            log "named.conf: добавлен include $name"
        fi
    }
    ensure_include options.conf
    ensure_include local.conf

    # rndc.key: гарантируем secret + algorithm
    pkg_try openssl || true
    ensure_rndc_key() {
        local keyf="$BIND_DIR/rndc.key" gen=""
        if [ -s "$keyf" ] && grep -q 'secret' "$keyf" && grep -q 'algorithm' "$keyf"; then return 0; fi
        log "Генерация $keyf"
        rm -f "$keyf"
        gen=$(command -v rndc-confgen || true)
        if [ -z "$gen" ] && [ -x /usr/sbin/rndc-confgen ]; then gen=/usr/sbin/rndc-confgen; fi
        if [ -n "$gen" ] && "$gen" -a -c "$keyf" >/dev/null 2>&1 && grep -q 'secret' "$keyf" 2>/dev/null; then
            log "rndc.key создан через rndc-confgen"
        else
            rm -f "$keyf"
            printf 'key "rndc-key" {\n\talgorithm hmac-sha256;\n\tsecret "%s";\n};\n' "$(openssl rand -base64 32)" > "$keyf"
            log "rndc.key создан вручную (openssl)"
        fi
        chown root:named "$keyf" 2>/dev/null || true
        chmod 640 "$keyf"
    }
    ensure_rndc_key
    if [ -f "$BIND_DIR/rndc.conf" ] && ! grep -Eq 'include[[:space:]]+"[^"]*rndc.key"' "$BIND_DIR/rndc.conf"; then
        write_file "$BIND_DIR/rndc.conf" 640 <<'NAMED'
include "/etc/bind/rndc.key";
options {
	default-key "rndc-key";
	default-server 127.0.0.1;
	default-port 953;
};
NAMED
        chown root:named "$BIND_DIR/rndc.conf" 2>/dev/null || true
    fi
    if grep -q '"rndc-key"' "$BIND_CONF" && ! grep -Eq '^[[:space:]]*include[[:space:]]+"[^"]*rndc.key"' "$BIND_CONF"; then
        echo 'include "/etc/bind/rndc.key";' >> "$BIND_CONF"
    fi

    dedupe_includes() { # убирает повторяющиеся строки include в named.conf
        local tmp; tmp=$(mktemp)
        awk '{ if ($0 ~ /^[[:space:]]*include[[:space:]]+"/) { k=$0; gsub(/[[:space:]]+/, " ", k); if (seen[k]++) next } print }' "$BIND_CONF" > "$tmp"
        if cmp -s "$tmp" "$BIND_CONF"; then
            rm -f "$tmp"
        else
            cp -a "$BIND_CONF" "$BACKUP_DIR/named.conf.dedupe.$(date +%s)"
            cat "$tmp" > "$BIND_CONF"
            rm -f "$tmp"
            log "named.conf: удалены дублирующиеся include"
        fi
    }
    dedupe_includes

    if getent group named >/dev/null; then
        chown -R root:named "$BIND_DIR" 2>/dev/null || true
        chmod 640 "$ZDIR"/* 2>/dev/null || true
    fi
    named-checkconf "$BIND_CONF" || die "named-checkconf: ошибка"
    named-checkzone demo.prof "$ZDIR/demo.prof"
    for z in 100 200 0 1 99; do
        named-checkzone "$z.168.192.in-addr.arpa" "$ZDIR/$z.168.192.in-addr.arpa"
    done
    NAMED_SVC=$(svc_first bind named) || die "служба bind/named не найдена"
    svc_enable "$NAMED_SVC"
    sleep 2
    if getent hosts "web.$DOMAIN" >/dev/null 2>&1; then log "DNS отвечает"; else warn "DNS пока не отвечает на web.$DOMAIN"; fi
fi

# =============================== МОДУЛЬ 2 ====================================
detect_raid_disks() { # печатает два свободных диска; RAID_DISKS="/dev/sdb /dev/sdc" — явное переопределение
    local name type kids mp d
    local found=() preferred=()
    if [ -n "${RAID_DISKS:-}" ]; then printf '%s\n' $RAID_DISKS; return 0; fi
    while read -r name type; do
        if [ "$type" != "disk" ]; then continue; fi
        kids=$(lsblk -nro NAME "$name" 2>/dev/null | sed -n '2,$p' || true)
        mp=$(lsblk -nro MOUNTPOINT "$name" 2>/dev/null | sed -n '/./p' || true)
        if [ -n "$kids" ] || [ -n "$mp" ]; then continue; fi          # есть разделы/монтирование — занят
        if blkid "$name" >/dev/null 2>&1; then continue; fi           # есть файловая система/подпись
        if grep -q "${name##*/}" /proc/mdstat 2>/dev/null; then continue; fi
        found+=("$name")
    done < <(lsblk -dnpo NAME,TYPE 2>/dev/null || true)
    # предпочитаем /dev/sdb и /dev/sdc, если они свободны
    for d in /dev/sdb /dev/sdc; do
        for name in "${found[@]}"; do
            if [ "$name" = "$d" ]; then preferred+=("$d"); fi
        done
    done
    if [ "${#preferred[@]}" -ge 2 ]; then printf '%s\n' "${preferred[0]}" "${preferred[1]}"; return 0; fi
    if [ "${#found[@]}" -ge 2 ]; then printf '%s\n' "${found[0]}" "${found[1]}"; return 0; fi
    return 1
}

setup_raid() {
    pkg mdadm e2fsprogs util-linux
    local md="" uuid d disks=()
    mdadm --assemble --scan >/dev/null 2>&1 || true
    md=$(awk '/^md[0-9]+ :/ {print "/dev/"$1; exit}' /proc/mdstat 2>/dev/null || true)
    if [ -z "$md" ]; then
        mapfile -t disks < <(detect_raid_disks || true)
        if [ "${#disks[@]}" -lt 2 ] || [ -z "${disks[0]:-}" ]; then
            warn "не найдено двух свободных дисков для RAID 0 — RAID пропущен (задайте RAID_DISKS=\"/dev/sdb /dev/sdc\")"
            return 0
        fi
        for d in "${disks[@]}"; do
            if [ ! -b "$d" ]; then warn "$d не является блочным устройством — RAID пропущен"; return 0; fi
            if grep -q "^$d " /proc/mounts; then warn "$d смонтирован — RAID пропущен"; return 0; fi
        done
        log "Создание RAID 0 (md0) из ${disks[*]} (содержимое дисков будет уничтожено)"
        wipefs -a "${disks[@]}" >/dev/null 2>&1 || true
        mdadm --create /dev/md0 --level=0 --raid-devices=2 --metadata=1.2 --run --force "${disks[@]}" <<< "y"
        md=/dev/md0
        sleep 2
    fi
    log "Массив: $md"
    mdadm --detail --scan > /etc/mdadm.conf
    if ! blkid "$md" >/dev/null 2>&1; then mkfs.ext4 -F -L raid "$md"; fi
    uuid=$(blkid -s UUID -o value "$md")
    mkdir -p /raid
    sed -i '\# /raid #d' /etc/fstab
    echo "UUID=$uuid /raid ext4 defaults,nofail 0 0" >> /etc/fstab
    if ! mountpoint -q /raid; then mount /raid; fi
    return 0
}

if want 2; then
    log "--- Модуль 2: RAID, NFS, Apache + MariaDB ---"
    chrony_client
    setup_raid

    pkg nfs-utils
    mkdir -p /raid/nfs
    chmod 777 /raid/nfs
    write_file /etc/exports <<'EXP'
/raid/nfs 192.168.200.0/28(rw,sync,no_subtree_check,no_root_squash)
EXP
    svc_enable "$(svc_first nfs-server nfs)"
    exportfs -ra

    # ---------------------------- Apache + PHP + MariaDB ----------------------------
    pkg apache2
    PHP_MOD=$(pkg_find '^apache2-mod_php[0-9.]+ ')
    if [ -z "$PHP_MOD" ]; then PHP_MOD=$(pkg_find '^apache2-mod_php'); fi
    [ -n "$PHP_MOD" ] || die "не найден пакет apache2-mod_php"
    pkg "$PHP_MOD"
    PHPV=${PHP_MOD#apache2-mod_php}
    pkg_try "php$PHPV-mysqlnd-mysqli" || true
    pkg_try "php$PHPV-mysqlnd" || true
    pkg_try "php$PHPV-pdo_mysql" || true

    pkg_any MariaDB-server mariadb-server MariaDB mariadb || die "не удалось установить MariaDB"
    pkg_any mariadb-client MariaDB-client mariadb MariaDB-server-client mysql-client >/dev/null 2>&1 || true
    command -v mysql >/dev/null 2>&1 || die "клиент mysql не найден (MariaDB-client/mariadb-client отсутствуют в репозитории)"

    if command -v a2enmod >/dev/null 2>&1; then
        for f in /etc/httpd2/conf/mods-available/php*.load; do
            if [ -f "$f" ]; then a2enmod "$(basename "${f%.load}")" >/dev/null 2>&1 || true; fi
        done
        if [ -f /etc/httpd2/conf/mods-available/mpm_prefork.load ]; then
            a2dismod mpm_event mpm_worker >/dev/null 2>&1 || true
            a2enmod mpm_prefork >/dev/null 2>&1 || true
        fi
    fi
    # Apache слушает 80 (для ISP-прокси) и 8080 (проброс с hq-rtr)
    if [ "$HQ_WEB_PORT" != "80" ]; then
        write_file /etc/httpd2/conf/addon.d/A.listen8080.conf <<APA
Listen $HQ_WEB_PORT
APA
    fi

    DB_SVC=$(svc_first mariadb mysqld mysql) || die "служба MariaDB не найдена"
    svc_enable "$DB_SVC"
    for i in $(seq 1 30); do
        if mysqladmin ping >/dev/null 2>&1; then break; fi
        sleep 1
    done
    DB=webdb; DBU=web
    mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS $DB CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '$DBU'@'localhost' IDENTIFIED BY '$PASS';
ALTER USER '$DBU'@'localhost' IDENTIFIED BY '$PASS';
GRANT ALL PRIVILEGES ON $DB.* TO '$DBU'@'localhost';
FLUSH PRIVILEGES;
SQL

    # материалы из Additional.iso/web: dump.sql, index.php, images
    WEB_SRC=$(find_extra d web || true)
    DUMP="${DUMP_SQL:-}"
    INDEX_SRC=""; IMAGES_SRC=""
    if [ -n "$WEB_SRC" ]; then
        if [ -z "$DUMP" ] && [ -f "$WEB_SRC/dump.sql" ]; then DUMP="$WEB_SRC/dump.sql"; fi
        if [ -f "$WEB_SRC/index.php" ]; then INDEX_SRC="$WEB_SRC/index.php"; fi
        if [ -d "$WEB_SRC/images" ]; then IMAGES_SRC="$WEB_SRC/images"; fi
    fi
    if [ -z "$DUMP" ]; then DUMP=$(find_extra f dump.sql || true); fi
    if [ -z "$INDEX_SRC" ]; then INDEX_SRC=$(find_extra f index.php || true); fi
    if [ -z "$IMAGES_SRC" ]; then IMAGES_SRC=$(find_extra d images || true); fi

    if [ -n "$DUMP" ] && [ -f "$DUMP" ]; then
        TBL=$(mysql -uroot -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB'")
        if [ "$TBL" = "0" ]; then
            log "Импорт $DUMP в $DB"
            mysql -uroot "$DB" < "$DUMP"
        else
            log "БД $DB уже содержит таблицы — импорт пропущен"
        fi
    else
        warn "dump.sql не найден (смонтируйте Additional.iso или задайте DUMP_SQL=/путь)"
    fi

    mkdir -p /var/www/html
    if [ -f /var/www/html/index.html ] && [ ! -f /var/www/html/index.html.orig ]; then
        mv /var/www/html/index.html /var/www/html/index.html.orig
    fi
    if [ -n "$INDEX_SRC" ]; then
        cp -f "$INDEX_SRC" /var/www/html/index.php
        log "index.php скопирован из $INDEX_SRC"
    else
        warn "index.php не найден — создан простой тестовый"
        write_file /var/www/html/index.php <<'PHP'
<?php
echo "<h1>HQ-SRV web</h1>";
mysqli_report(MYSQLI_REPORT_OFF);
$c = @new mysqli('localhost', 'web', 'P@ssword', 'webdb');
echo $c->connect_errno ? "DB: ошибка подключения" : "DB webdb: подключение успешно";
PHP
    fi
    if [ -n "$IMAGES_SRC" ]; then
        mkdir -p /var/www/html/images
        cp -a "$IMAGES_SRC"/. /var/www/html/images/
        log "каталог images скопирован из $IMAGES_SRC"
    fi
    write_file /etc/httpd2/conf/addon.d/A.directoryindex.conf <<'APA'
DirectoryIndex index.php index.html
APA
    chown -R apache2:apache2 /var/www/html 2>/dev/null || true
    svc_enable "$(svc_first httpd2 apache2 httpd)"
fi

# =============================== МОДУЛЬ 3 ====================================
CA=/root/ca
CA_DAYS=365
CERT_DAYS=20
UCERTS=/home/user/certs
GOSTENG=""

cert_valid() { # действителен и осталось более 2 суток
    [ -f "$1" ] && openssl x509 -checkend 172800 -noout -in "$1" >/dev/null 2>&1
}
issue_rsa() { # <имя>
    local n="$1" d="$CA/rsa"
    if cert_valid "$d/$n.crt"; then return 0; fi
    openssl genrsa -out "$d/$n.key" 2048
    openssl req -new -key "$d/$n.key" -subj "/C=RU/O=DEMO.PROF/CN=$n.demo.prof" -out "$d/$n.csr"
    printf 'subjectAltName=DNS:%s.demo.prof\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$n" > "$d/$n.ext"
    openssl x509 -req -in "$d/$n.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -CAcreateserial \
        -out "$d/$n.crt" -days "$CERT_DAYS" -sha256 -extfile "$d/$n.ext"
}
make_gost_ca() {
    if cert_valid "$CA/gost/ca.crt"; then return 0; fi
    openssl req $GOSTENG -x509 -newkey gost2012_256 -pkeyopt paramset:A -nodes \
        -keyout "$CA/gost/ca.key" -out "$CA/gost/ca.crt" -days "$CA_DAYS" \
        -subj "/C=RU/O=DEMO.PROF/CN=DEMO.PROF Root CA (GOST)" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"
}
issue_gost() { # <имя> (вызывается в if — каждую команду связываем через &&)
    local n="$1" d="$CA/gost"
    if cert_valid "$d/$n.crt"; then return 0; fi
    openssl req $GOSTENG -new -newkey gost2012_256 -pkeyopt paramset:A -nodes \
        -keyout "$d/$n.key" -out "$d/$n.csr" -subj "/C=RU/O=DEMO.PROF/CN=$n.demo.prof" &&
    printf 'subjectAltName=DNS:%s.demo.prof\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$n" > "$d/$n.ext" &&
    openssl x509 $GOSTENG -req -in "$d/$n.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -CAcreateserial \
        -out "$d/$n.crt" -days "$CERT_DAYS" -extfile "$d/$n.ext"
}

if want 3; then
    log "--- Модуль 3: CA (ГОСТ), CUPS, rsyslog, atop, fail2ban, бэкап ---"

    # ------------------------- Удостоверяющий центр -------------------------
    pkg openssl
    mkdir -p "$CA/rsa" "$CA/gost"
    chmod 700 "$CA"
    if [ ! -f "$CA/rsa/ca.crt" ] || ! cert_valid "$CA/rsa/ca.crt"; then
        openssl genrsa -out "$CA/rsa/ca.key" 4096
        openssl req -x509 -new -key "$CA/rsa/ca.key" -sha256 -days "$CA_DAYS" \
            -subj "/C=RU/O=DEMO.PROF/CN=DEMO.PROF Root CA (RSA)" \
            -addext "basicConstraints=critical,CA:TRUE" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" \
            -out "$CA/rsa/ca.crt"
    fi
    issue_rsa web
    issue_rsa docker

    pkg_try openssl-gost-engine || true
    control openssl-gost enabled >/dev/null 2>&1 || true
    ENG_OUT=$(openssl engine -t gost 2>&1 || true)
    if [[ "$ENG_OUT" == *available* ]]; then GOSTENG="-engine gost"; fi
    ALG_OUT=$(openssl list -public-key-algorithms 2>/dev/null || true)
    GOST_DONE=0
    if [ -n "$GOSTENG" ] || [[ "$ALG_OUT" == *gost2012* ]]; then
        if make_gost_ca && issue_gost web && issue_gost docker; then
            GOST_DONE=1
        else
            warn "ГОСТ-сертификаты не созданы (RSA работают)"
        fi
    else
        warn "gost-engine недоступен — ГОСТ-сертификаты пропущены"
    fi

    # публикация: домашний каталог user (scp для ISP) и HTTP /ca/ для клиентов
    mkdir -p "$UCERTS/rsa" "$UCERTS/gost"
    for n in ca web docker; do
        cp -f "$CA/rsa/$n.crt" "$UCERTS/rsa/$n.crt"
        if [ "$n" != "ca" ]; then cp -f "$CA/rsa/$n.key" "$UCERTS/rsa/$n.key"; fi
        if [ "$GOST_DONE" = 1 ]; then
            cp -f "$CA/gost/$n.crt" "$UCERTS/gost/$n.crt"
            if [ "$n" != "ca" ]; then cp -f "$CA/gost/$n.key" "$UCERTS/gost/$n.key"; fi
        fi
    done
    chown -R user:user "$UCERTS"
    chmod 700 "$UCERTS" "$UCERTS/rsa" "$UCERTS/gost"
    chmod 600 "$UCERTS"/rsa/*.key "$UCERTS"/gost/*.key 2>/dev/null || true
    chmod 644 "$UCERTS"/rsa/*.crt "$UCERTS"/gost/*.crt 2>/dev/null || true

    mkdir -p /var/www/html/ca
    cp -f "$CA/rsa/ca.crt" /var/www/html/ca/ca-rsa.crt
    cp -f "$CA/rsa/ca.crt" /var/www/html/ca/ca.crt
    cp -f "$CA/rsa/ca.crt" /var/www/html/ca.crt
    if [ "$GOST_DONE" = 1 ]; then cp -f "$CA/gost/ca.crt" /var/www/html/ca/ca-gost.crt; fi
    chmod 755 /var/www/html/ca
    chmod 644 /var/www/html/ca/* /var/www/html/ca.crt

    # ---------------------------------- CUPS ----------------------------------
    pkg cups
    pkg_try cups-pdf || true
    svc_enable cups
    sleep 2
    if ! lpstat -p PDF >/dev/null 2>&1; then
        lpadmin -p PDF -E -v cups-pdf:/ -m lsb/usr/cups-pdf/CUPS-PDF_noopt.ppd 2>/dev/null \
          || lpadmin -p PDF -E -v cups-pdf:/ -m everywhere 2>/dev/null \
          || warn "не удалось создать виртуальный PDF-принтер (проверьте пакет cups-pdf)"
    fi
    lpoptions -d PDF >/dev/null 2>&1 || true
    cupsctl --remote-any --share-printers >/dev/null 2>&1 || warn "cupsctl не применён"
    lpadmin -p PDF -o printer-is-shared=true >/dev/null 2>&1 || true

    # --------------------------- rsyslog-сервер ---------------------------
    pkg_any rsyslog rsyslog-classic || die "не удалось установить rsyslog"
    mkdir -p /opt
    write_file /etc/rsyslog.d/remote.conf <<'RSY'
$CreateDirs on
$FileCreateMode 0640
$DirCreateMode 0755
module(load="imudp")
input(type="imudp" port="514")
module(load="imtcp")
input(type="imtcp" port="514")
template(name="RemFile" type="string" string="/opt/%HOSTNAME%/%HOSTNAME%.log")
# только удалённые сообщения уровня warning и выше; сервер сам себя в /opt не пишет
if ($fromhost-ip != '127.0.0.1' and $hostname != 'hq-srv' and $hostname != 'hq-srv.demo.prof' and $syslogseverity <= 4) then {
    action(type="omfile" dynaFile="RemFile")
    stop
}
RSY
    write_file /etc/logrotate.d/remote-logs <<'LRT'
/opt/*/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    minsize 10M
    missingok
    notifempty
}
LRT
    svc_enable "$(svc_first rsyslog rsyslogd)"

    # ----------------------------- мониторинг atop -----------------------------
    pkg atop
    if [ -f /etc/sysconfig/atop ]; then
        if grep -q '^LOGINTERVAL=' /etc/sysconfig/atop; then
            sed -i 's/^LOGINTERVAL=.*/LOGINTERVAL=600/' /etc/sysconfig/atop
        else
            echo 'LOGINTERVAL=600' >> /etc/sysconfig/atop
        fi
    else
        echo 'LOGINTERVAL=600' > /etc/sysconfig/atop
    fi
    svc_enable atop
    for lbl in CPU MEM DSK NET; do
        OUT=$(atop -P "$lbl" 1 2 2>/dev/null | sed -n '1,3p' || true)
        if [ -n "$OUT" ]; then log "atop $lbl: OK"; else warn "atop не вернул метрику $lbl"; fi
    done

    # -------------------------------- fail2ban --------------------------------
    pkg fail2ban iptables
    write_file /etc/fail2ban/jail.local <<F2B
[DEFAULT]
bantime  = 2m
findtime = 10m
maxretry = 2

[sshd]
enabled = true
port    = $SSH_PORT_SRV
backend = systemd
F2B
    svc_enable fail2ban

    # --------------- резервное копирование -> HQ-CLI:/backup ---------------
    pkg_try cronie || true
    pkg_try rsync || true
    pkg_try sshpass || true
    write_file /usr/local/bin/hq-backup.sh 755 <<'BKP'
#!/bin/bash
# Резервная копия /etc и базы webdb -> hq-cli:/backup (пользователь irpoadmin)
TS=$(date +%F_%H%M)
DST=/var/backups/hq
mkdir -p "$DST"
tar czf "$DST/etc-$TS.tgz" /etc 2>/dev/null || true
mysqldump webdb | gzip > "$DST/webdb-$TS.sql.gz"
export SSHPASS='P@ssword'
sshpass -e rsync -a -e "ssh -p 22 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
    "$DST/" irpoadmin@hq-cli.demo.prof:/backup/
find "$DST" -type f -mtime +7 -delete
BKP
    write_file /etc/cron.d/hq-backup <<'CRN'
0 2 * * * root /usr/local/bin/hq-backup.sh >> /var/log/hq-backup.log 2>&1
CRN
    svc_enable "$(svc_first crond cron)" || true
    if /usr/local/bin/hq-backup.sh >/dev/null 2>&1; then
        log "пробное резервное копирование выполнено"
    else
        warn "пробное резервное копирование не прошло (hq-cli ещё не настроен?)"
    fi
    # ---------------- проверка статуса служб после запуска ----------------
    check_service() { # <метка> <юнит...>
        local label="$1" unit; shift
        if ! unit=$(svc_first "$@"); then warn "$label: служба не найдена"; return 1; fi
        if systemctl is-active --quiet "$unit"; then
            log "$label: active ($unit)"
            return 0
        fi
        warn "$label: НЕ запущена ($unit)"
        systemctl status "$unit" --no-pager -l 2>&1 | sed -n '1,8p' || true
        return 1
    }
    check_service "fail2ban" fail2ban || true
    F2B_OUT=$(fail2ban-client status sshd 2>&1 || true)
    if [[ "$F2B_OUT" == *"Currently banned"* ]]; then log "fail2ban jail sshd: активен"; else warn "fail2ban jail sshd не отвечает: $F2B_OUT"; fi
    check_service "CUPS" cups cupsd || true
    CUPS_OUT=$(lpstat -r 2>&1 || true)
    PRN_OUT=$(lpstat -p PDF 2>&1 || true)
    if [[ "$CUPS_OUT" == *"is running"* ]]; then log "CUPS: планировщик запущен"; else warn "CUPS: $CUPS_OUT"; fi
    if [[ "$PRN_OUT" == *PDF* && "$PRN_OUT" != *"does not exist"* ]]; then log "CUPS: очередь PDF доступна"; else warn "CUPS: очередь PDF недоступна: $PRN_OUT"; fi
fi

echo "=== hq-srv.sh configured successfully ==="
