#!/bin/bash
# =============================================================================
# hq-cli.sh — автоматическая настройка стенда (ALT Linux p10/p11)
# Запуск: MODULE=1|2|3|all ./hq-cli.sh   (по умолчанию all). Идемпотентен.
# Переменные: TZ_NAME (Asia/Krasnoyarsk), IFACE, DUMP_SQL, USERS_CSV, ...
# =============================================================================
set -Eeuo pipefail

SCRIPT_NAME="hq-cli.sh"
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
CA_HOST=192.168.100.2
ANCH=/etc/pki/ca-trust/source/anchors
HAVE_GOST=0

# =============================== МОДУЛЬ 1 ====================================
if want 1; then
    log "--- Модуль 1: имя, время, DHCP, администратор ---"
    set_hostname hq-cli.$DOMAIN 127.0.1.1
    set_tz
    NET_BEFORE=$(net_hash)
    net_options "$IFACE" dhcp
    rm -f "/etc/net/ifaces/$IFACE/ipv4address" "/etc/net/ifaces/$IFACE/ipv4route"
    net_apply "$NET_BEFORE"
    wait_ip "$IFACE" 40
    # администратор и SSH нужны для Ansible (BR-SRV) — клиент входит в группу «роутеров»: admin
    add_admin admin
    ssh_setup 22
fi

# =============================== МОДУЛЬ 2 ====================================
domain_joined() {
    local st
    st=$(system-auth status 2>/dev/null || true)
    [[ "${st^^}" == *"DEMO.PROF"* ]]
}

if want 2; then
    log "--- Модуль 2: chrony, домен, NFS, Яндекс Браузер ---"
    chrony_client

    pkg task-auth-ad-sssd
    log "Ожидание DNS-записей контроллера домена..."
    DC_OK=0
    for i in $(seq 1 20); do
        if getent hosts "br-srv.$DOMAIN" >/dev/null 2>&1; then DC_OK=1; break; fi
        sleep 3
    done
    if [ "$DC_OK" -ne 1 ]; then warn "br-srv.$DOMAIN не резолвится — проверьте DHCP/DNS и работу hq-srv/br-srv"; fi

    if domain_joined; then
        log "Машина уже в домене DEMO.PROF — пропуск"
    else
        joined=0
        for i in 1 2 3 4 5; do
            if system-auth write ad DEMO.PROF hq-cli DEMO Administrator "$PASS"; then joined=1; break; fi
            warn "Попытка ввода в домен $i/5 неудачна, повтор через 10с"
            sleep 10
        done
        if [ "$joined" -ne 1 ]; then die "Не удалось ввести машину в домен"; fi
        log "Машина введена в домен (рекомендуется перезагрузка)"
    fi
    if getent passwd "hquser1@$DOMAIN" >/dev/null 2>&1; then
        log "проверка входа: пользователь hquser1@$DOMAIN виден в домене"
    else
        warn "hquser1@$DOMAIN пока не виден (SSSD подхватит после перезагрузки или после br-srv.sh)"
    fi

    # NFS: автомонтирование 192.168.100.2:/raid/nfs -> /mnt/nfs
    pkg nfs-utils
    mkdir -p /mnt/nfs
    sed -i '\# /mnt/nfs #d' /etc/fstab
    echo "192.168.100.2:/raid/nfs /mnt/nfs nfs defaults,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=60,x-systemd.mount-timeout=15 0 0" >> /etc/fstab
    systemctl daemon-reload
    systemctl restart mnt-nfs.automount 2>/dev/null || warn "automount-юнит mnt-nfs.automount не запущен"
    if ls /mnt/nfs >/dev/null 2>&1; then log "NFS доступен"; else warn "NFS пока недоступен (проверьте hq-srv)"; fi

    # Яндекс Браузер (best effort)
    if ! rpm -q yandex-browser-stable >/dev/null 2>&1; then
        if command -v epm >/dev/null 2>&1; then
            epm -y play yandex-browser || warn "epm play yandex-browser не удался"
        else
            pkg_try yandex-browser-stable || warn "Яндекс Браузер не установлен (нет epm и пакета)"
        fi
    fi
fi

# =============================== МОДУЛЬ 3 ====================================
wait_ca() { # ждём готовности веб-сервера и сертификатов на hq-srv
    local i
    for i in $(seq 1 60); do
        if curl -fsI -m 5 "http://$CA_HOST/ca/ca-rsa.crt" >/dev/null 2>&1; then return 0; fi
        log "Ожидание сертификатов на hq-srv ($i/60)..."
        sleep 5
    done
    return 1
}
fetch_ca() { # <файл на сервере> <локальное имя> <rsa|gost>
    local tmp url
    tmp=$(mktemp)
    for url in "http://$CA_HOST/ca/$1" "http://$CA_HOST/ca/ca.crt" "http://$CA_HOST/ca.crt"; do
        if [ "$3" = gost ] && [ "$url" != "http://$CA_HOST/ca/$1" ]; then continue; fi
        if curl -fsS --connect-timeout 10 -o "$tmp" "$url" 2>/dev/null && grep -q 'BEGIN CERTIFICATE' "$tmp"; then
            mv "$tmp" "$ANCH/$2"; chmod 644 "$ANCH/$2"; return 0
        fi
    done
    rm -f "$tmp"
    if command -v sshpass >/dev/null 2>&1 || pkg_try sshpass; then
        if sshpass -p "$PASS" scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 "user@$CA_HOST:certs/$3/ca.crt" "$ANCH/$2" 2>/dev/null; then
            chmod 644 "$ANCH/$2"; return 0
        fi
    fi
    return 1
}
add_nss() { # <домашний каталог>
    local h="$1" db owner
    if [ ! -d "$h" ]; then return 0; fi
    if [ ! -s "$ANCH/demo-ca-rsa.crt" ]; then warn "NSS: нет $ANCH/demo-ca-rsa.crt"; return 1; fi
    db="$h/.pki/nssdb"
    mkdir -p "$db"
    if [ ! -f "$db/cert9.db" ]; then
        certutil -N -d "sql:$db" --empty-password || { warn "NSS: не удалось создать базу в $db"; return 1; }
    fi
    certutil -D -d "sql:$db" -n "DEMO CA RSA" >/dev/null 2>&1 || true
    certutil -A -d "sql:$db" -t "CT,C,C" -n "DEMO CA RSA" -i "$ANCH/demo-ca-rsa.crt" || { warn "NSS: не удалось добавить RSA CA в $db"; return 1; }
    if [ "$HAVE_GOST" = 1 ] && [ -s "$ANCH/demo-ca-gost.crt" ]; then
        certutil -D -d "sql:$db" -n "DEMO CA GOST" >/dev/null 2>&1 || true
        certutil -A -d "sql:$db" -t "CT,C,C" -n "DEMO CA GOST" -i "$ANCH/demo-ca-gost.crt" || warn "NSS: не удалось добавить ГОСТ CA в $db"
    fi
    if [ -d "$h/.pki" ]; then
        owner=$(stat -c '%U:%G' "$h" 2>/dev/null || true)
        if [ -n "$owner" ]; then
            chown -R "$owner" "$h/.pki" 2>/dev/null || warn "NSS: chown $h/.pki не выполнен"
        fi
    fi
    return 0
}

if want 3; then
    log "--- Модуль 3: доверие к CA, принтер, каталог резервных копий ---"
    pkg ca-certificates curl
    pkg_any nss-utils libnss-utils || warn "nss-utils не установлен — NSS-хранилища будут пропущены"
    mkdir -p "$ANCH"

    if ! wait_ca; then warn "HTTP-доступ к /ca/ на hq-srv недоступен — пробуем scp"; fi
    fetch_ca ca-rsa.crt demo-ca-rsa.crt rsa || die "Не удалось получить RSA CA с HQ-SRV (сначала hq-srv.sh MODULE=3)"
    if fetch_ca ca-gost.crt demo-ca-gost.crt gost; then HAVE_GOST=1; else warn "ГОСТ CA недоступен — пропуск"; fi
    update-ca-trust extract 2>/dev/null || update-ca-trust 2>/dev/null || warn "update-ca-trust не выполнен"

    if command -v certutil >/dev/null 2>&1; then
        for h in /root /etc/skel /home/*; do
            if [ -d "$h" ]; then add_nss "$h" || warn "NSS: не удалось обработать $h"; fi
        done
    else
        warn "certutil не найден — NSS-хранилища не обновлены"
    fi

    # Firefox: политика (корни предприятия + явная установка CA)
    FF_LIST="\"$ANCH/demo-ca-rsa.crt\""
    if [ "$HAVE_GOST" = 1 ] && [ -s "$ANCH/demo-ca-gost.crt" ]; then
        FF_LIST="$FF_LIST, \"$ANCH/demo-ca-gost.crt\""
    fi
    FF_JSON=$(printf '{\n  "policies": {\n    "Certificates": {\n      "ImportEnterpriseRoots": true,\n      "Install": [ %s ]\n    }\n  }\n}' "$FF_LIST")
    if command -v python3 >/dev/null 2>&1; then
        printf '%s\n' "$FF_JSON" | python3 -c 'import json,sys; json.load(sys.stdin)' || die "policies.json для Firefox — невалидный JSON"
    fi
    for d in /etc/firefox/policies /usr/lib64/firefox/distribution /usr/lib/firefox/distribution /usr/lib64/firefox-esr/distribution; do
        if [ "$d" = /etc/firefox/policies ] || [ -d "$(dirname "$d")" ]; then
            printf '%s\n' "$FF_JSON" | write_file "$d/policies.json"
        fi
    done

    # принтер по умолчанию: виртуальный PDF-принтер с HQ-SRV
    pkg_try cups || true
    pkg_try cups-pdf || true
    mkdir -p /etc/cups
    write_file /etc/cups/client.conf <<'CUP'
ServerName 192.168.100.2
CUP
    # очередь PDF доступна на hq-srv -> явно назначаем принтером по умолчанию
    if lpstat -p PDF >/dev/null 2>&1; then
        if lpadmin -d PDF 2>/dev/null || lpoptions -d PDF >/dev/null 2>&1; then
            DEF_OUT=$(lpstat -d 2>/dev/null || true)
            log "принтер по умолчанию: ${DEF_OUT:-PDF}"
        else
            warn "не удалось назначить PDF принтером по умолчанию"
        fi
    else
        warn "очередь PDF на hq-srv недоступна (hq-srv.sh MODULE=3 выполнен?) — принтер по умолчанию не назначен"
    fi

    # хранилище резервных копий HQ-SRV
    if ! id irpoadmin >/dev/null 2>&1; then useradd -m -s /bin/bash irpoadmin; fi
    echo "irpoadmin:$PASS" | chpasswd
    pkg_try rsync || true
    mkdir -p /backup
    chown irpoadmin:irpoadmin /backup
    chmod 750 /backup
    log "каталог /backup готов (владелец irpoadmin)"
fi

echo "=== hq-cli.sh configured successfully ==="
