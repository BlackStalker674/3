#!/bin/bash
# =============================================================================
# isp.sh — автоматическая настройка стенда (ALT Linux p10/p11)
# Идемпотентный: повторный запуск безопасен. Лог: /var/log/<имя>.log
# =============================================================================
set -Ee

SCRIPT_NAME="isp.sh"
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

MODE="${1:-http}"
case "$MODE" in
    http|tls) ;;
    *) die "Использование: $0 [tls]   (без аргумента — HTTP, tls — HTTPS с сертификатами HQ-SRV)" ;;
esac
log "Режим работы: $MODE"

WAN_IF=enp7s1; HQ_IF=enp7s2; BR_IF=enp7s3

# ---------------------------------------------------------------- 1. Сеть ----
set_hostname isp.$DOMAIN 127.0.1.1
NET_BEFORE=$(net_hash)
net_options "$WAN_IF" dhcp
net_options "$HQ_IF";  net_addr "$HQ_IF" 172.16.1.1/28
net_options "$BR_IF";  net_addr "$BR_IF" 172.16.2.1/28
# маршруты во внутренние сети офисов (нужны reverse proxy и scp)
net_routes "$HQ_IF" "192.168.100.0/27 via 172.16.1.2" \
                    "192.168.200.0/28 via 172.16.1.2" \
                    "192.168.99.0/29 via 172.16.1.2"
net_routes "$BR_IF" "192.168.0.0/29 via 172.16.2.2" \
                    "192.168.1.0/30 via 172.16.2.2" \
                    "192.168.1.16/28 via 172.16.2.2"
enable_forward
net_apply "$NET_BEFORE"

# ----------------------------------------------------------------- 2. NAT ----
ipt_add nat POSTROUTING -s 172.16.1.0/28 -o "$WAN_IF" -j MASQUERADE
ipt_add nat POSTROUTING -s 172.16.2.0/28 -o "$WAN_IF" -j MASQUERADE
ipt_save
log "NAT настроен"

# ---------------------------------------------------------------- 3. NTP -----
pkg chrony
write_file /etc/chrony.conf <<'EOF'
# ISP — локальный источник времени (stratum 5)
local stratum 5
allow 172.16.0.0/16
allow 192.168.0.0/16
allow 10.10.10.0/30
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
svc_enable "$(svc_first chronyd chrony)"

# --------------------------------------------------------------- 4. SSH ------
ssh_setup 2026
add_admin net_admin
log "SSH слушает порт 2026"

# -------------------------------------------------------------- 5. Nginx -----
pkg nginx openssl
mkdir -p /etc/nginx/sites-available.d /etc/nginx/sites-enabled.d
if ! grep -q 'sites-enabled.d' /etc/nginx/nginx.conf; then
    sed -i '0,/http[[:space:]]*{/s//http {\n    include \/etc\/nginx\/sites-enabled.d\/*.conf;/' /etc/nginx/nginx.conf
fi
rm -f /etc/nginx/sites-enabled.d/default.conf /etc/nginx/sites-enabled.d/default

# Basic Auth (WEBC / P@ssword)
if [ ! -s /etc/nginx/.htpasswd ]; then
    echo "WEBC:$(openssl passwd -apr1 "$PASS")" > /etc/nginx/.htpasswd
fi
chmod 640 /etc/nginx/.htpasswd
chgrp nginx /etc/nginx/.htpasswd 2>/dev/null || true

write_file /etc/nginx/proxy_params.conf <<'EOF'
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_connect_timeout 10s;
proxy_read_timeout 60s;
EOF

build_http_conf() {
    write_file /etc/nginx/sites-available.d/proxy.conf <<'EOF'
# --- HTTP reverse proxy ---
server {
    listen 80;
    server_name web.demo.prof;
    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;
    location / {
        include /etc/nginx/proxy_params.conf;
        proxy_pass http://192.168.100.2:80;
    }
}
server {
    listen 80;
    server_name docker.demo.prof;
    location / {
        include /etc/nginx/proxy_params.conf;
        proxy_pass http://192.168.0.2:8080;
    }
}
EOF
}

# ------- получение сертификатов (режим tls) -------
SSL=/etc/nginx/ssl
HAVE_GOST=0
fetch_certs() {
    pkg sshpass openssh-clients
    local tmp port ok=0
    tmp=$(mktemp -d)
    for port in 2026; do
        log "scp сертификатов с HQ-SRV (порт $port)..."
        if sshpass -p "$PASS" scp -r -P "$port" -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
              "sshuser@192.168.100.2:certs" "$tmp/"; then
            ok=1; break
        fi
    done
    if [ "$ok" -ne 1 ]; then rm -rf "$tmp"; die "Не удалось скопировать сертификаты с HQ-SRV (сначала запустите hq-srv.sh)"; fi

    mkdir -p "$SSL/rsa" "$SSL/gost"
    chmod 700 "$SSL"
    local kind n
    for kind in rsa gost; do
        if [ -d "$tmp/certs/$kind" ]; then
            for n in web docker; do
                if [ -f "$tmp/certs/$kind/$n.crt" ] && [ -f "$tmp/certs/$kind/$n.key" ]; then
                    cat "$tmp/certs/$kind/$n.crt" "$tmp/certs/$kind/ca.crt" > "$SSL/$kind/$n.fullchain.crt"
                    cp -f "$tmp/certs/$kind/$n.key" "$SSL/$kind/$n.key"
                    cp -f "$tmp/certs/$kind/ca.crt" "$SSL/$kind/ca.crt"
                    chmod 600 "$SSL/$kind/$n.key"
                fi
            done
        fi
    done
    rm -rf "$tmp"
    if [ ! -f "$SSL/rsa/web.fullchain.crt" ]; then die "RSA-сертификаты не найдены после копирования"; fi
    if [ -f "$SSL/gost/web.fullchain.crt" ] && [ -f "$SSL/gost/docker.fullchain.crt" ]; then HAVE_GOST=1; fi
    log "Сертификаты получены (ГОСТ: $HAVE_GOST)"
}

ssl_block() { # <web|docker>
    local n="$1" out
    out="ssl_certificate $SSL/rsa/$n.fullchain.crt;"$'\n'"    ssl_certificate_key $SSL/rsa/$n.key;"
    if [ "$HAVE_GOST" = 1 ]; then
        out+=$'\n'"    ssl_certificate $SSL/gost/$n.fullchain.crt;"$'\n'"    ssl_certificate_key $SSL/gost/$n.key;"
    fi
    printf '%s' "$out"
}

build_tls_conf() {
    local ciphers="HIGH:!aNULL:!MD5"
    if [ "$HAVE_GOST" = 1 ]; then
        ciphers="HIGH:!aNULL:!MD5:GOST2012-KUZNYECHIK-KUZNYECHIKOMAC:GOST2012-MAGMA-MAGMAOMAC:GOST2012-GOST8912-GOST8912:GOST2001-GOST89-GOST89"
    fi
    local tpl
    tpl=$(cat <<'EOF'
# --- HTTP -> HTTPS + reverse proxy ---
server {
    listen 80 default_server;
    server_name _;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    server_name web.demo.prof;
    @@SSL_WEB@@
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers @@CIPHERS@@;
    ssl_prefer_server_ciphers on;
    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;
    location / {
        include /etc/nginx/proxy_params.conf;
        proxy_pass http://192.168.100.2:80;
    }
}
server {
    listen 443 ssl;
    server_name docker.demo.prof;
    @@SSL_DOCKER@@
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers @@CIPHERS@@;
    ssl_prefer_server_ciphers on;
    location / {
        include /etc/nginx/proxy_params.conf;
        proxy_pass http://192.168.0.2:8080;
    }
}
EOF
)
    tpl=${tpl//@@SSL_WEB@@/$(ssl_block web)}
    tpl=${tpl//@@SSL_DOCKER@@/$(ssl_block docker)}
    tpl=${tpl//@@CIPHERS@@/$ciphers}
    printf '%s\n' "$tpl" | write_file /etc/nginx/sites-available.d/proxy.conf
}

if [ "$MODE" = "tls" ]; then
    fetch_certs
    build_tls_conf
else
    build_http_conf
fi
ln -sf /etc/nginx/sites-available.d/proxy.conf /etc/nginx/sites-enabled.d/proxy.conf

if ! nginx -t; then
    if [ "$MODE" = "tls" ] && [ "$HAVE_GOST" = 1 ]; then
        warn "nginx не принял ГОСТ-конфигурацию — переключаюсь только на RSA"
        HAVE_GOST=0
        build_tls_conf
        nginx -t || die "nginx -t: ошибка конфигурации"
    else
        die "nginx -t: ошибка конфигурации"
    fi
fi
svc_enable nginx
log "Nginx настроен ($MODE)"

echo "=== isp.sh configured successfully ==="
