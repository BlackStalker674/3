#!/bin/bash
# =============================================================================
# br-srv.sh — автоматическая настройка стенда (ALT Linux p10/p11)
# Идемпотентный: повторный запуск безопасен. Лог: /var/log/<имя>.log
# =============================================================================
set -Ee

SCRIPT_NAME="br-srv.sh"
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

IFACE=$(detect_iface "${IFACE:-enp7s1}")
log "Рабочий интерфейс: $IFACE"

# ---------------------------------------------------------------- 1. Сеть ----
set_hostname br-srv.$DOMAIN 192.168.0.2
NET_BEFORE=$(net_hash)
net_options "$IFACE"
net_addr    "$IFACE" 192.168.0.2/29
net_routes  "$IFACE" "default via 192.168.0.1"
# до развёртывания DC DNS даёт hq-srv, после — сам Samba
if [ ! -f /var/lib/samba/private/sam.ldb ]; then
    printf 'search %s\nnameserver 192.168.100.2\n' "$DOMAIN" | write_file "/etc/net/ifaces/$IFACE/resolv.conf"
    printf 'search %s\nnameserver 192.168.100.2\n' "$DOMAIN" > /etc/resolv.conf 2>/dev/null || true
fi
net_apply "$NET_BEFORE"

# ----------------------------------------------------------- 2. Samba DC -----
pkg_any task-samba-dc || die "не удалось установить task-samba-dc"
for s in smb nmb winbind krb5kdc slapd bind named; do
    systemctl disable --now "$s" >/dev/null 2>&1 || true
done

if [ ! -f /var/lib/samba/private/sam.ldb ]; then
    log "Provision домена DEMO.PROF"
    systemctl stop samba >/dev/null 2>&1 || true
    # ВАЖНО: перед provision удаляем старый smb.conf и чистим остатки
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba /var/cache/samba
    mkdir -p /var/lib/samba/sysvol
    samba-tool domain provision \
        --realm=DEMO.PROF --domain=DEMO \
        --adminpass="$PASS" \
        --dns-backend=SAMBA_INTERNAL \
        --server-role=dc --use-rfc2307 \
        --option="dns forwarder=192.168.100.2"
else
    log "Домен уже развёрнут — provision пропущен"
fi

# krb5.conf, сгенерированный Samba, копируем в /etc
if [ -f /var/lib/samba/private/krb5.conf ]; then
    cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
fi

# после развёртывания DNS — собственный (Samba internal)
printf 'search %s\nnameserver 192.168.0.2\n' "$DOMAIN" | write_file "/etc/net/ifaces/$IFACE/resolv.conf"
printf 'search %s\nnameserver 192.168.0.2\n' "$DOMAIN" > /etc/resolv.conf 2>/dev/null || true

svc_enable samba
for i in $(seq 1 60); do
    if ss -ltn 2>/dev/null | grep -q ':389 '; then break; fi
    sleep 1
done
testparm -s >/dev/null 2>&1 || warn "testparm сообщил о замечаниях"

# политика паролей (P@ssw0rd — 8 символов, поэтому min-length = 8)
samba-tool domain passwordsettings set \
    --complexity=on --history-length=3 \
    --min-pwd-length=8 --min-pwd-age=0 --max-pwd-age=90
samba-tool user setexpiry Administrator --noexpiry >/dev/null 2>&1 || true

# группа и пользователи hquser1..10
if ! samba-tool group show hq >/dev/null 2>&1; then samba-tool group add hq; fi
for i in $(seq 1 10); do
    u="hquser$i"
    if ! samba-tool user show "$u" >/dev/null 2>&1; then
        samba-tool user create "$u" "$PASS"
        log "создан пользователь $u"
    fi
    samba-tool user setexpiry "$u" --noexpiry >/dev/null 2>&1 || true
    samba-tool group addmembers hq "$u" >/dev/null 2>&1 || true
done

# импорт пользователей из users.csv (если файл найден на ISO/диске)
CSV=""
for c in "${USERS_CSV:-}" /root/users.csv /opt/users.csv /mnt/additional/users.csv /mnt/*/users.csv /media/*/users.csv /home/*/users.csv; do
    if [ -n "$c" ] && [ -f "$c" ]; then CSV="$c"; break; fi
done
if [ -n "$CSV" ]; then
    log "Импорт пользователей из $CSV"
    DELIM=';'; if [ "$(head -1 "$CSV" | tr -cd ',' | wc -c)" -gt "$(head -1 "$CSV" | tr -cd ';' | wc -c)" ]; then DELIM=','; fi
    awk -F"$DELIM" 'BEGIN{IGNORECASE=1}
        NR==1{for(i=1;i<=NF;i++){h=tolower($i); if(h~/login|user|логин/)l=i; if(h~/pass|парол/)p=i}
               if(l){next} else {l=1;p=2}}
        {gsub(/\r/,""); if($l!="") print $l "\t" (p?$p:"")}' "$CSV" |
    while IFS=$'\t' read -r u pw; do
        if [ -z "$pw" ]; then pw="$PASS"; fi
        if ! samba-tool user show "$u" >/dev/null 2>&1; then
            samba-tool user create "$u" "$pw" || warn "не удалось создать $u"
        fi
    done
else
    log "users.csv не найден — импорт пропущен (hquser1..10 созданы выше)"
fi

if echo "$PASS" | kinit "administrator@DEMO.PROF" >/dev/null 2>&1; then
    log "Kerberos: kinit administrator — успешно"; kdestroy >/dev/null 2>&1 || true
else
    warn "kinit не прошёл (проверьте время и DNS)"
fi

# --- время: Kerberos чувствителен к расхождению (источник — ISP, stratum 4) ---
pkg chrony
write_file /etc/chrony.conf <<'EOT'
server 172.16.1.1 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOT
svc_enable "$(svc_first chronyd chrony)"

# ----------------------------------------------------------- 3. Docker -------
pkg_any docker-engine docker-ce docker.io || die "не удалось установить Docker"
svc_enable docker
for i in $(seq 1 20); do
    if docker info >/dev/null 2>&1; then break; fi
    sleep 1
done

IMG="${TESTAPP_IMAGE:-testapp:latest}"
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
    # 1) локальный архив образа
    for f in "${TESTAPP_IMAGE_TAR:-}" /root/testapp*.tar /opt/testapp*.tar /mnt/additional/docker/*.tar /media/*/docker/*.tar /home/*/testapp*.tar; do
        if [ -n "$f" ] && [ -f "$f" ]; then
            log "docker load < $f"
            docker load -i "$f" && break
        fi
    done
fi
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
    # 2) загрузка из реестра, если имя образа содержит реестр
    docker pull "$IMG" >/dev/null 2>&1 || true
fi
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
    warn "образ $IMG не найден — использую nginx:alpine как заглушку testapp"
    docker pull nginx:alpine || die "нет образа testapp и не удалось скачать nginx:alpine (положите tar в /root/testapp.tar или задайте TESTAPP_IMAGE)"
    docker tag nginx:alpine testapp:latest
    IMG=testapp:latest
fi

# внутренний порт приложения: из EXPOSE образа, иначе TESTAPP_PORT_IN, иначе 80
PORT_IN=$(docker image inspect -f '{{range $p,$_ := .Config.ExposedPorts}}{{println $p}}{{end}}' "$IMG" 2>/dev/null | head -n1 | cut -d/ -f1)
PORT_IN="${TESTAPP_PORT_IN:-${PORT_IN:-80}}"
log "Запуск контейнера testapp: 8080 -> $PORT_IN"
docker rm -f testapp >/dev/null 2>&1 || true
docker run -d --name testapp --restart unless-stopped -p 8080:"$PORT_IN" "$IMG"
sleep 3
if curl -fsS -m 5 http://127.0.0.1:8080/ >/dev/null 2>&1; then log "testapp отвечает на :8080"; else warn "testapp пока не отвечает на :8080"; fi

add_master

# ------------------------------------------------------------- 4. SSH --------
pkg openssh-server
write_file /etc/openssh/banner <<'EOF'
Banner!!!!
EOF
sshd_ports 2222
sshd_set Banner /etc/openssh/banner
sshd_set MaxAuthTries 2
sshd_reload

echo "=== br-srv.sh configured successfully ==="
