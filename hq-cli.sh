#!/bin/bash
# =============================================================================
# hq-cli.sh — автоматическая настройка стенда (ALT Linux p10/p11)
# Идемпотентный: повторный запуск безопасен. Лог: /var/log/<имя>.log
# =============================================================================
set -Ee

SCRIPT_NAME="hq-cli.sh"
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
set_hostname hq-cli.$DOMAIN 127.0.1.1
NET_BEFORE=$(net_hash)
net_options "$IFACE" dhcp
rm -f "/etc/net/ifaces/$IFACE/ipv4address" "/etc/net/ifaces/$IFACE/ipv4route"
net_apply "$NET_BEFORE"
wait_ip "$IFACE" 40

# --- время: Kerberos чувствителен к расхождению (источник — ISP, stratum 4) ---
pkg chrony
write_file /etc/chrony.conf <<'EOT'
server 172.16.1.1 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOT
svc_enable "$(svc_first chronyd chrony)"

# --------------------------------------------------- 2. Ввод в домен ---------
pkg task-auth-ad-sssd
pkg_try openssh-clients || true

log "Ожидание DNS-записей контроллера домена..."
DC_OK=0
for i in $(seq 1 20); do
    if getent hosts "br-srv.$DOMAIN" >/dev/null 2>&1; then DC_OK=1; break; fi
    sleep 3
done
if [ "$DC_OK" -ne 1 ]; then warn "br-srv.$DOMAIN не резолвится — проверьте DHCP/DNS и работу hq-srv/br-srv"; fi

if system-auth status 2>/dev/null | grep -qi 'DEMO.PROF'; then
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

# ------------------------------------------------------------- 3. NFS --------
pkg nfs-utils
mkdir -p /mnt/nfs
sed -i '\# /mnt/nfs #d' /etc/fstab
echo "192.168.100.2:/raid0/nfs /mnt/nfs nfs defaults,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=60,x-systemd.mount-timeout=15 0 0" >> /etc/fstab
systemctl daemon-reload
systemctl restart mnt-nfs.automount 2>/dev/null || warn "automount-юнит mnt-nfs.automount не запущен"
ls /mnt/nfs >/dev/null 2>&1 && log "NFS доступен" || warn "NFS пока недоступен (проверьте hq-srv)"

# ---------------------------------------------- 4. Доверие к корневым CA -----
pkg ca-certificates curl
pkg_any nss-utils libnss-utils || warn "nss-utils не установлен — NSS-хранилища будут пропущены"

ANCH=/etc/pki/ca-trust/source/anchors
mkdir -p "$ANCH"
CA_HOST=192.168.100.2
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
    local tmp url port
    tmp=$(mktemp)
    for url in "http://$CA_HOST/ca/$1" "http://$CA_HOST/ca/ca.crt" "http://$CA_HOST/ca.crt"; do
        if [ "$3" = gost ] && [ "$url" != "http://$CA_HOST/ca/$1" ]; then continue; fi
        if curl -fsS --connect-timeout 10 -o "$tmp" "$url" 2>/dev/null && grep -q 'BEGIN CERTIFICATE' "$tmp"; then
            mv "$tmp" "$ANCH/$2"; chmod 644 "$ANCH/$2"; return 0
        fi
    done
    rm -f "$tmp"
    if command -v sshpass >/dev/null 2>&1 || pkg_try sshpass; then
        for port in 2027 2222; do
            if sshpass -p "$PASS" scp -P "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=10 "userssh@$CA_HOST:certs/$3/ca.crt" "$ANCH/$2" 2>/dev/null; then
                chmod 644 "$ANCH/$2"; return 0
            fi
        done
    fi
    return 1
}
if ! wait_ca; then warn "HTTP-доступ к /ca/ на hq-srv недоступен — пробуем scp"; fi
fetch_ca ca-rsa.crt demo-ca-rsa.crt rsa || die "Не удалось получить RSA CA с HQ-SRV"
HAVE_GOST=0
if fetch_ca ca-gost.crt demo-ca-gost.crt gost; then HAVE_GOST=1; else warn "ГОСТ CA недоступен — пропуск"; fi

update-ca-trust extract 2>/dev/null || update-ca-trust 2>/dev/null || warn "update-ca-trust не выполнен"

# --- NSS (Chromium/curl-nss и т.п.): root, /etc/skel и все домашние каталоги ---
add_nss() { # <домашний каталог>
    local h="$1" db owner
    db="$h/.pki/nssdb"
    mkdir -p "$db"
    if [ ! -f "$db/cert9.db" ]; then certutil -N -d "sql:$db" --empty-password; fi
    certutil -D -d "sql:$db" -n "DEMO CA RSA" >/dev/null 2>&1 || true
    certutil -A -d "sql:$db" -t "CT,C,C" -n "DEMO CA RSA" -i "$ANCH/demo-ca-rsa.crt"
    if [ "$HAVE_GOST" = 1 ]; then
        certutil -D -d "sql:$db" -n "DEMO CA GOST" >/dev/null 2>&1 || true
        certutil -A -d "sql:$db" -t "CT,C,C" -n "DEMO CA GOST" -i "$ANCH/demo-ca-gost.crt"
    fi
    owner=$(stat -c '%U:%G' "$h")
    chown -R "$owner" "$h/.pki"
}
if command -v certutil >/dev/null 2>&1; then
    for h in /root /etc/skel /home/*; do
        if [ -d "$h" ]; then add_nss "$h" || warn "NSS: не удалось обработать $h"; fi
    done
else
    warn "certutil не найден — NSS-хранилища не обновлены"
fi

# --- Firefox: политика (корни предприятия + явная установка CA) ---
FF_CERTS='"'"$ANCH/demo-ca-rsa.crt"'"'
if [ "$HAVE_GOST" = 1 ]; then FF_CERTS="$FF_CERTS, \"$ANCH/demo-ca-gost.crt\""; fi
FF_JSON=$(cat <<EOF
{
  "policies": {
    "Certificates": {
      "ImportEnterpriseRoots": true,
      "Install": [ $FF_CERTS ]
    }
  }
}
EOF
)
for d in /etc/firefox/policies /usr/lib64/firefox/distribution /usr/lib/firefox/distribution /usr/lib64/firefox-esr/distribution; do
    if [ "$d" = /etc/firefox/policies ] || [ -d "$(dirname "$d")" ]; then
        printf '%s\n' "$FF_JSON" | write_file "$d/policies.json"
    fi
done

# --- Яндекс Браузер (best effort) ---
if ! rpm -q yandex-browser-stable >/dev/null 2>&1; then
    if command -v epm >/dev/null 2>&1; then
        epm -y play yandex-browser || warn "epm play yandex-browser не удался"
    else
        pkg_try yandex-browser-stable || warn "Яндекс Браузер не установлен (нет epm и пакета)"
    fi
fi

echo "=== hq-cli.sh configured successfully ==="
