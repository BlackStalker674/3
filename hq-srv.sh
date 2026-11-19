#!/bin/bash
# =============================================================================
# hq-srv.sh — автоматическая настройка стенда (ALT Linux p10/p11)
# Идемпотентный: повторный запуск безопасен. Лог: /var/log/<имя>.log
# =============================================================================
set -Ee

SCRIPT_NAME="hq-srv.sh"
LOG_FILE="/var/log/${SCRIPT_NAME%.sh}.log"
BACKUP_DIR="/var/backups/${SCRIPT_NAME%.sh}"
DOMAIN="demo.prof"
PASS='P@ssword'

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
ensure_dns() { # резервный публичный DNS, если имена не резолвятся
    local i
    for i in 1 2 3 4 5; do
        if getent hosts ftp.altlinux.org >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    if ! grep -q '77.88.8.8' /etc/resolv.conf 2>/dev/null; then
        echo 'nameserver 77.88.8.8' >> /etc/resolv.conf
        log "DNS: добавлен резервный сервер 77.88.8.8"
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
ipt_ready() { if ! command -v iptables >/dev/null 2>&1; then pkg iptables; fi; }
ipt_add() { # <таблица> <цепочка> <правило...>  (идемпотентно)
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
    echo ": PSK \"P@ssword\"" > /etc/ipsec.secrets
    chmod 600 /etc/ipsec.secrets
    if [ "$cdir" != "/etc" ]; then
        echo ": PSK \"P@ssword\"" > "$cdir/ipsec.secrets"
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

add_admin() { # <user> [uid] — администратор с sudo без пароля
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

ssh_setup() { # <порт...> : порт, баннер, ключи, перезапуск sshd
    pkg openssh-server
    write_file /etc/openssh/banner <<'EOT'
Authorized access only
EOT
    sshd_ports "$@"
    sshd_set Banner /etc/openssh/banner
    sshd_reload
}

rsyslog_client() { # пересылка логов (warning и выше) на hq-srv
    if ! pkg_any rsyslog rsyslog-classic; then warn "rsyslog не установлен — пересылка логов пропущена"; return 0; fi
    write_file /etc/rsyslog.d/forward.conf <<'EOT'
*.warning @@192.168.100.2:514
EOT
    svc_enable rsyslog
}

mount_extra() { # монтирует Additional.iso (если есть привод) в /mnt/additional
    local d
    if [ -d /mnt/additional ] && [ -n "$(ls -A /mnt/additional 2>/dev/null)" ]; then return 0; fi
    mkdir -p /mnt/additional
    for d in /dev/sr0 /dev/sr1 /dev/cdrom; do
        if [ -b "$d" ] && mount -o ro "$d" /mnt/additional 2>/dev/null; then
            log "Additional.iso смонтирован из $d"
            return 0
        fi
    done
    return 0
}
find_extra() { # <f|d> <имя/шаблон> -> путь
    local t="$1" n="$2" r res
    mount_extra
    for r in /mnt/additional /media /root /opt /home /mnt/cdrom; do
        if [ -d "$r" ]; then
            res=$(find "$r" -maxdepth 4 -type "$t" -name "$n" 2>/dev/null | head -n1)
            if [ -n "$res" ]; then echo "$res"; return 0; fi
        fi
    done
    return 1
}

IFACE=$(detect_iface "${IFACE:-enp7s1}")
log "Рабочий интерфейс: $IFACE"

# ---------------------------------------------------------------- 1. Сеть ----
set_hostname hq-srv.$DOMAIN 192.168.100.2
NET_BEFORE=$(net_hash)
net_options "$IFACE"
net_addr    "$IFACE" 192.168.100.2/27
net_routes  "$IFACE" "default via 192.168.100.1"
printf 'search %s\noptions timeout:1 attempts:2\nnameserver 127.0.0.1\nnameserver 77.88.8.8\n' "$DOMAIN" | write_file "/etc/net/ifaces/$IFACE/resolv.conf"
net_apply "$NET_BEFORE"
printf 'search %s\noptions timeout:1 attempts:2\nnameserver 127.0.0.1\nnameserver 77.88.8.8\n' "$DOMAIN" > /etc/resolv.conf 2>/dev/null || true

chrony_client

# ------------------------------------------------------------- 2. DNS (BIND) -
pkg bind bind-utils
BIND_CONF=/etc/bind/named.conf
if [ ! -f "$BIND_CONF" ]; then BIND_CONF=/var/lib/bind/etc/named.conf; fi
[ -f "$BIND_CONF" ] || die "не найден named.conf"
BIND_DIR=$(dirname "$BIND_CONF")
ZDIR="$BIND_DIR/zone"
mkdir -p "$ZDIR"
SERIAL="$(date +%Y%m%d)01"

write_file "$BIND_DIR/options.conf" <<'EOF'
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
EOF

write_file "$BIND_DIR/local.conf" <<'EOF'
zone "demo.prof" { type master; file "demo.prof"; allow-update { none; }; };
zone "100.168.192.in-addr.arpa" { type master; file "100.168.192.in-addr.arpa"; };
zone "200.168.192.in-addr.arpa" { type master; file "200.168.192.in-addr.arpa"; };
zone "0.168.192.in-addr.arpa"   { type master; file "0.168.192.in-addr.arpa"; };
zone "1.168.192.in-addr.arpa"   { type master; file "1.168.192.in-addr.arpa"; };
EOF

SRV_T="br-srv.demo.prof."
write_file "$ZDIR/demo.prof" <<EOF
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
docker  IN A 172.16.2.1
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
EOF

mk_rev() { # <файл> <записи PTR из stdin>
    {
        printf '$TTL 1h\n'
        printf '@ IN SOA hq-srv.demo.prof. admin.demo.prof. ( %s 1h 15m 1w 1h )\n' "$SERIAL"
        printf '@ IN NS hq-srv.demo.prof.\n'
        cat
    } | write_file "$ZDIR/$1"
}
mk_rev 100.168.192.in-addr.arpa <<'EOF'
1 IN PTR hq-rtr.demo.prof.
2 IN PTR hq-srv.demo.prof.
EOF
mk_rev 200.168.192.in-addr.arpa <<'EOF'
1 IN PTR hq-rtr.demo.prof.
2 IN PTR hq-cli.demo.prof.
EOF
mk_rev 0.168.192.in-addr.arpa <<'EOF'
1 IN PTR br-fw.demo.prof.
2 IN PTR br-srv.demo.prof.
EOF
mk_rev 1.168.192.in-addr.arpa <<'EOF'
1  IN PTR br-rtr.demo.prof.
2  IN PTR br-fw.demo.prof.
17 IN PTR br-fw.demo.prof.
EOF

if getent group named >/dev/null; then
    chown -R root:named "$BIND_DIR" 2>/dev/null || true
    chmod 640 "$ZDIR"/* 2>/dev/null || true
fi

# --- главный named.conf должен подключать options.conf и local.conf ---
ensure_include() { # <имя файла>
    local name="$1" re
    re="include[[:space:]]+\"[^\"]*/${name//./\\.}\""
    if grep -Eq "^[[:space:]]*$re" "$BIND_CONF"; then
        log "named.conf: include $name уже есть"
    elif grep -Eq "^[[:space:]]*(//|#)+[[:space:]]*$re" "$BIND_CONF"; then
        cp -a "$BIND_CONF" "$BACKUP_DIR/named.conf.$(date +%s)"
        sed -i -E "s|^[[:space:]]*(//\|#)+[[:space:]]*($re)|\2|" "$BIND_CONF"
        log "named.conf: include $name раскомментирован"
    else
        cp -a "$BIND_CONF" "$BACKUP_DIR/named.conf.$(date +%s)"
        echo "include \"$BIND_INC/$name\";" >> "$BIND_CONF"
        log "named.conf: добавлен include $name"
    fi
}
BIND_INC=/etc/bind
if [ "$BIND_CONF" != "/etc/bind/named.conf" ]; then BIND_INC="$BIND_DIR"; fi
# встроенный блок options в самом named.conf конфликтует с options.conf
if grep -Eq '^[[:space:]]*options[[:space:]]*\{' "$BIND_CONF"; then
    warn "в named.conf найден встроенный блок options — переписываю named.conf на include-схему (копия в $BACKUP_DIR)"
    cp -a "$BIND_CONF" "$BACKUP_DIR/named.conf.$(date +%s)"
    {
        echo "include \"$BIND_INC/options.conf\";"
        if [ -f "$BIND_DIR/rndc.key" ]; then echo "include \"$BIND_INC/rndc.key\";"; fi
        echo "include \"$BIND_INC/local.conf\";"
    } > "$BIND_CONF"
fi
ensure_include options.conf
ensure_include local.conf

# --- гарантируем, что named.conf подключает options.conf и local.conf ---
ensure_include() { # <имя файла>
    local name="$1"
    if grep -Eq "^[[:space:]]*include[[:space:]]+\"[^\"]*/?${name}\"" "$BIND_CONF"; then
        return 0
    fi
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

# --- rndc.key: гарантируем наличие корректного ключа (secret + algorithm) ---
pkg_try openssl || true
ensure_rndc_key() {
    local keyf="$BIND_DIR/rndc.key" gen
    if [ -s "$keyf" ] && grep -q 'secret' "$keyf" && grep -q 'algorithm' "$keyf"; then
        return 0
    fi
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
    write_file "$BIND_DIR/rndc.conf" 640 <<'EOF'
include "/etc/bind/rndc.key";
options {
	default-key "rndc-key";
	default-server 127.0.0.1;
	default-port 953;
};
EOF
    chown root:named "$BIND_DIR/rndc.conf" 2>/dev/null || true
fi
if grep -q '"rndc-key"' "$BIND_CONF" && ! grep -Eq '^[[:space:]]*include[[:space:]]+"[^"]*rndc.key"' "$BIND_CONF"; then
    echo 'include "/etc/bind/rndc.key";' >> "$BIND_CONF"
fi

# проверка конфигурации и зон
named-checkconf "$BIND_CONF" || die "named-checkconf: ошибка"
named-checkzone demo.prof "$ZDIR/demo.prof"
named-checkzone 100.168.192.in-addr.arpa "$ZDIR/100.168.192.in-addr.arpa"
named-checkzone 200.168.192.in-addr.arpa "$ZDIR/200.168.192.in-addr.arpa"
named-checkzone 0.168.192.in-addr.arpa   "$ZDIR/0.168.192.in-addr.arpa"
named-checkzone 1.168.192.in-addr.arpa   "$ZDIR/1.168.192.in-addr.arpa"

NAMED_SVC=$(svc_first bind named) || die "служба bind/named не найдена"
svc_enable "$NAMED_SVC"
sleep 2
getent hosts web.$DOMAIN >/dev/null && log "DNS отвечает" || warn "DNS пока не отвечает на web.$DOMAIN"

# ------------------------------------------------------------ 3. RAID 0 ------
setup_raid() {
    pkg mdadm e2fsprogs util-linux
    # По ТЗ: RAID 0 из /dev/sdb и /dev/sdc (RAID_LEVEL=5 — только по явному запросу, нужен /dev/sdd)
    local level="${RAID_LEVEL:-0}" md="" d disks=()
    if [ "$level" = 5 ]; then disks=(/dev/sdb /dev/sdc /dev/sdd); else level=0; disks=(/dev/sdb /dev/sdc); fi
    for d in "${disks[@]}"; do
        if [ ! -b "$d" ]; then warn "$d отсутствует — RAID пропущен"; return 0; fi
    done
    mdadm --assemble --scan >/dev/null 2>&1 || true
    md=$(awk '/^md[0-9]+ :/ {print "/dev/"$1; exit}' /proc/mdstat 2>/dev/null)
    if [ -z "$md" ]; then
        for d in "${disks[@]}"; do
            if mount | grep -q "^$d"; then warn "$d смонтирован — RAID пропущен"; return 0; fi
        done
        log "Создание RAID$level из ${disks[*]} (содержимое дисков будет уничтожено)"
        wipefs -a "${disks[@]}" >/dev/null 2>&1 || true
        mdadm --create /dev/md0 --level="$level" --raid-devices="${#disks[@]}" --metadata=1.2 --run --force "${disks[@]}" <<< "y"
        md=/dev/md0
        sleep 2
    fi
    log "Массив: $md (RAID$level)"
    mdadm --detail --scan > /etc/mdadm.conf
    if ! blkid "$md" >/dev/null 2>&1; then mkfs.ext4 -F -L raid "$md"; fi
    local uuid; uuid=$(blkid -s UUID -o value "$md")
    mkdir -p /raid
    sed -i '\# /raid #d' /etc/fstab
    echo "UUID=$uuid /raid ext4 defaults,nofail 0 0" >> /etc/fstab
    if ! mountpoint -q /raid; then mount /raid; fi
    return 0
}
setup_raid

# ------------------------------------------------------------ 4. NFS ---------
pkg nfs-utils
mkdir -p /raid/nfs
chmod 777 /raid/nfs
write_file /etc/exports <<'EOF'
/raid/nfs 192.168.200.0/28(rw,sync,no_subtree_check,no_root_squash)
EOF
svc_enable "$(svc_first nfs-server nfs)"
exportfs -ra

# ------------------------------------------------- 5. Apache + PHP + MariaDB -
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
write_file /etc/httpd2/conf/addon.d/A.listen8080.conf <<'EOF'
Listen 8080
EOF

DB_SVC=$(svc_first mariadb mysqld mysql) || die "служба MariaDB не найдена"
svc_enable "$DB_SVC"
for i in $(seq 1 30); do
    if mysqladmin ping >/dev/null 2>&1; then break; fi
    sleep 1
done
DB=webdb; DBU=webc
mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS $DB CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '$DBU'@'localhost' IDENTIFIED BY '$PASS';
ALTER USER '$DBU'@'localhost' IDENTIFIED BY '$PASS';
GRANT ALL PRIVILEGES ON $DB.* TO '$DBU'@'localhost';
FLUSH PRIVILEGES;
EOF

# импорт схемы из dump.sql (Additional.iso)
DUMP="${DUMP_SQL:-$(find_extra f dump.sql || true)}"
if [ -n "$DUMP" ] && [ -f "$DUMP" ]; then
    TBL=$(mysql -uroot -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB'")
    if [ "$TBL" = "0" ]; then
        log "Импорт $DUMP в $DB"
        mysql -uroot "$DB" < "$DUMP"
    else
        log "БД $DB уже содержит таблицы — импорт пропущен"
    fi
else
    warn "dump.sql не найден (положите Additional.iso в привод или задайте DUMP_SQL=/путь)"
fi

# файлы приложения: index.php и каталог images
mkdir -p /var/www/html
if [ -f /var/www/html/index.html ] && [ ! -f /var/www/html/index.html.orig ]; then
    mv /var/www/html/index.html /var/www/html/index.html.orig
fi
INDEX_SRC=$(find_extra f index.php || true)
IMAGES_SRC=$(find_extra d images || true)
if [ -n "$INDEX_SRC" ]; then
    cp -f "$INDEX_SRC" /var/www/html/index.php
    log "index.php скопирован из $INDEX_SRC"
else
    warn "index.php не найден — создан простой тестовый"
    write_file /var/www/html/index.php <<'EOF'
<?php
echo "<h1>HQ-SRV web</h1>";
mysqli_report(MYSQLI_REPORT_OFF);
$c = @new mysqli('localhost', 'webc', 'P@ssword', 'webdb');
echo $c->connect_errno ? "DB: ошибка подключения" : "DB webdb: подключение успешно";
EOF
fi
if [ -n "$IMAGES_SRC" ]; then
    mkdir -p /var/www/html/images
    cp -a "$IMAGES_SRC"/. /var/www/html/images/
    log "каталог images скопирован из $IMAGES_SRC"
fi
write_file /etc/httpd2/conf/addon.d/A.directoryindex.conf <<'EOF'
DirectoryIndex index.php index.html
EOF
chown -R apache2:apache2 /var/www/html 2>/dev/null || true
svc_enable "$(svc_first httpd2 apache2 httpd)"

# --------------------------------------------------------------- 6. CUPS -----
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

# -------------------------------------------- 7. Администратор sshuser (UID 2026) ----
add_admin sshuser 2026
if ! id irpoadmin >/dev/null 2>&1; then useradd -m -s /bin/bash irpoadmin; fi
echo "irpoadmin:$PASS" | chpasswd

# ----------------------------------------------- 8. Удостоверяющий центр -----
pkg openssl
CA=/root/ca
mkdir -p "$CA/rsa" "$CA/gost"
chmod 700 "$CA"

# ---- RSA ----
if [ ! -f "$CA/rsa/ca.crt" ]; then
    openssl genrsa -out "$CA/rsa/ca.key" 4096
    openssl req -x509 -new -key "$CA/rsa/ca.key" -sha256 -days 3650 \
        -subj "/C=RU/O=DEMO.PROF/CN=DEMO.PROF Root CA (RSA)" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -out "$CA/rsa/ca.crt"
fi
issue_rsa() { # <имя>
    local n="$1" d="$CA/rsa"
    if [ -f "$d/$n.crt" ]; then return 0; fi
    openssl genrsa -out "$d/$n.key" 2048
    openssl req -new -key "$d/$n.key" -subj "/C=RU/O=DEMO.PROF/CN=$n.demo.prof" -out "$d/$n.csr"
    printf 'subjectAltName=DNS:%s.demo.prof\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$n" > "$d/$n.ext"
    openssl x509 -req -in "$d/$n.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -CAcreateserial \
        -out "$d/$n.crt" -days 825 -sha256 -extfile "$d/$n.ext"
}
issue_rsa web
issue_rsa docker

# ---- ГОСТ (если доступен gost-engine) ----
pkg_try openssl-gost-engine || true
control openssl-gost enabled >/dev/null 2>&1 || true
GOSTENG=""
if openssl engine -t gost 2>&1 | grep -q 'available'; then GOSTENG="-engine gost"; fi
gost_ok() { openssl list -public-key-algorithms 2>/dev/null | grep -qi 'gost2012' || [ -n "$GOSTENG" ]; }

issue_gost() { # <имя>   (функция вызывается в if, каждую команду страхуем через &&)
    local n="$1" d="$CA/gost"
    if [ -f "$d/$n.crt" ]; then return 0; fi
    openssl req $GOSTENG -new -newkey gost2012_256 -pkeyopt paramset:A -nodes \
        -keyout "$d/$n.key" -out "$d/$n.csr" -subj "/C=RU/O=DEMO.PROF/CN=$n.demo.prof" &&
    printf 'subjectAltName=DNS:%s.demo.prof\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$n" > "$d/$n.ext" &&
    openssl x509 $GOSTENG -req -in "$d/$n.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -CAcreateserial \
        -out "$d/$n.crt" -days 825 -extfile "$d/$n.ext"
}
make_gost_ca() {
    if [ -f "$CA/gost/ca.crt" ]; then return 0; fi
    openssl req $GOSTENG -x509 -newkey gost2012_256 -pkeyopt paramset:A -nodes \
        -keyout "$CA/gost/ca.key" -out "$CA/gost/ca.crt" -days 3650 \
        -subj "/C=RU/O=DEMO.PROF/CN=DEMO.PROF Root CA (GOST)" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"
}
GOST_DONE=0
if gost_ok; then
    if make_gost_ca && issue_gost web && issue_gost docker; then GOST_DONE=1; else warn "ГОСТ-сертификаты не созданы (RSA работают)"; fi
else
    warn "gost-engine недоступен — ГОСТ-сертификаты пропущены"
fi

# ---- публикация сертификатов ----
UCERTS=/home/sshuser/certs
mkdir -p "$UCERTS/rsa" "$UCERTS/gost"
for n in ca web docker; do
    cp -f "$CA/rsa/$n.crt" "$UCERTS/rsa/$n.crt"
    if [ "$n" != "ca" ]; then cp -f "$CA/rsa/$n.key" "$UCERTS/rsa/$n.key"; fi
    if [ "$GOST_DONE" = 1 ]; then
        cp -f "$CA/gost/$n.crt" "$UCERTS/gost/$n.crt"
        if [ "$n" != "ca" ]; then cp -f "$CA/gost/$n.key" "$UCERTS/gost/$n.key"; fi
    fi
done
chown -R sshuser:sshuser "$UCERTS"
chmod 700 "$UCERTS" "$UCERTS/rsa" "$UCERTS/gost"
chmod 600 "$UCERTS"/rsa/*.key "$UCERTS"/gost/*.key 2>/dev/null || true
chmod 644 "$UCERTS"/rsa/*.crt "$UCERTS"/gost/*.crt 2>/dev/null || true

# публичные корневые сертификаты по HTTP для клиентов (без ключей!)
mkdir -p /var/www/html/ca
cp -f "$CA/rsa/ca.crt" /var/www/html/ca/ca-rsa.crt
cp -f "$CA/rsa/ca.crt" /var/www/html/ca/ca.crt
cp -f "$CA/rsa/ca.crt" /var/www/html/ca.crt
if [ "$GOST_DONE" = 1 ]; then cp -f "$CA/gost/ca.crt" /var/www/html/ca/ca-gost.crt; fi
chmod 644 /var/www/html/ca.crt
chmod 755 /var/www/html/ca; chmod 644 /var/www/html/ca/*

# -------------------------------------------------------- 9. SSH + Fail2ban --
ssh_setup 2026
sshd_set PasswordAuthentication yes
sshd_set MaxAuthTries 2
sshd_set AllowUsers sshuser
sshd_reload

pkg fail2ban iptables
write_file /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1m
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port    = 2026
backend = systemd
EOF
svc_enable fail2ban

# ------------------------------------------- 10. rsyslog-сервер + logrotate --
pkg_any rsyslog rsyslog-classic || die "не удалось установить rsyslog"
mkdir -p /opt
write_file /etc/rsyslog.d/remote.conf <<'EOF'
$CreateDirs on
$FileCreateMode 0640
$DirCreateMode 0755
module(load="imudp")
input(type="imudp" port="514")
module(load="imtcp")
input(type="imtcp" port="514")
template(name="RemFile" type="string" string="/opt/%HOSTNAME%/%HOSTNAME%.log")
if ($fromhost-ip != '127.0.0.1' and $syslogseverity <= 4) then {
    action(type="omfile" dynaFile="RemFile")
    stop
}
EOF
write_file /etc/logrotate.d/remote-logs <<'EOF'
/opt/*/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    minsize 10M
    missingok
    notifempty
}
EOF
svc_enable "$(svc_first rsyslog rsyslogd)"

# ------------------------------- 11. Резервное копирование на HQ-CLI:/backup --
pkg_try cronie || true
pkg_try rsync || true
pkg_try sshpass || true
write_file /usr/local/bin/hq-backup.sh 755 <<'EOF'
#!/bin/bash
# Резервная копия /etc и базы webdb -> hq-cli:/backup (пользователь irpoadmin)
TS=$(date +%F_%H%M)
DST=/var/backups/hq
mkdir -p "$DST"
tar czf "$DST/etc-$TS.tgz" /etc 2>/dev/null || true
mysqldump webdb | gzip > "$DST/webdb-$TS.sql.gz"
export SSHPASS='P@ssword'
sshpass -e rsync -a -e "ssh -p 2026 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
    "$DST/" irpoadmin@hq-cli.demo.prof:/backup/
find "$DST" -type f -mtime +7 -delete
EOF
write_file /etc/cron.d/hq-backup <<'EOF'
0 2 * * * root /usr/local/bin/hq-backup.sh >> /var/log/hq-backup.log 2>&1
EOF
svc_enable "$(svc_first crond cron)" || true
/usr/local/bin/hq-backup.sh >/dev/null 2>&1 || warn "пробное резервное копирование не прошло (hq-cli ещё не настроен?)"

# ----------------------------------------------- 11. Мониторинг atop (10 мин) -
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

echo "=== hq-srv.sh configured successfully ==="
