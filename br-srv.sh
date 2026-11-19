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
set_hostname br-srv.$DOMAIN 192.168.0.2
NET_BEFORE=$(net_hash)
net_options "$IFACE"
net_addr    "$IFACE" 192.168.0.2/29
net_routes  "$IFACE" "default via 192.168.0.1"
# до развёртывания DC DNS даёт hq-srv, после — сам Samba
if [ ! -f /var/lib/samba/private/sam.ldb ]; then
    printf 'search %s\noptions timeout:1 attempts:2\nnameserver 77.88.8.8\nnameserver 192.168.100.2\n' "$DOMAIN" | write_file "/etc/net/ifaces/$IFACE/resolv.conf"
    printf 'search %s\noptions timeout:1 attempts:2\nnameserver 77.88.8.8\nnameserver 192.168.100.2\n' "$DOMAIN" > /etc/resolv.conf 2>/dev/null || true
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
        --option="dns forwarder=77.88.8.8"
else
    log "Домен уже развёрнут — provision пропущен"
fi

# krb5.conf, сгенерированный Samba, копируем в /etc
if [ -f /var/lib/samba/private/krb5.conf ]; then
    cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
fi

# после развёртывания DNS — собственный (Samba internal)
printf 'search %s\noptions timeout:1 attempts:2\nnameserver 192.168.0.2\nnameserver 77.88.8.8\n' "$DOMAIN" | write_file "/etc/net/ifaces/$IFACE/resolv.conf"
printf 'search %s\noptions timeout:1 attempts:2\nnameserver 192.168.0.2\nnameserver 77.88.8.8\n' "$DOMAIN" > /etc/resolv.conf 2>/dev/null || true

svc_enable samba
for i in $(seq 1 60); do
    if ss -ltn 2>/dev/null | grep -q ':389 '; then break; fi
    sleep 1
done
testparm -s >/dev/null 2>&1 || warn "testparm сообщил о замечаниях"

# политика паролей (P@ssword — 8 символов, поэтому min-length = 8)
samba-tool domain passwordsettings set \
    --complexity=on --history-length=3 \
    --min-pwd-length=8 --min-pwd-age=0 --max-pwd-age=90
samba-tool user setexpiry Administrator --noexpiry >/dev/null 2>&1 || true

# группа и пользователи hquser1..10
if ! samba-tool group show hq >/dev/null 2>&1; then samba-tool group add hq; fi
for i in $(seq 1 5); do
    u="hquser$i"
    if ! samba-tool user show "$u" >/dev/null 2>&1; then
        samba-tool user create "$u" "$PASS"
        log "создан пользователь $u"
    fi
    samba-tool user setexpiry "$u" --noexpiry >/dev/null 2>&1 || true
    samba-tool group addmembers hq "$u" >/dev/null 2>&1 || true
done

# импорт пользователей из users.csv (Additional.iso) со всеми атрибутами
CSV="${USERS_CSV:-$(find_extra f users.csv || true)}"
if [ -n "$CSV" ] && [ -f "$CSV" ]; then
    log "Импорт пользователей из $CSV"
    DELIM=';'
    if [ "$(head -1 "$CSV" | tr -cd ',' | wc -c)" -gt "$(head -1 "$CSV" | tr -cd ';' | wc -c)" ]; then DELIM=','; fi
    awk -F"$DELIM" -v OFS="\037" '
        function col(n) { return (n > 0) ? $n : "" }
        NR==1 {
            for (i=1; i<=NF; i++) {
                raw=$i; gsub(/\r|"/,"",raw); h=tolower(raw)
                if (raw ~ /(Логин|логин|ЛОГИН|Имя пользователя|имя пользователя)/ || h ~ /login|username|user name|samaccount/) L=i
                else if (raw ~ /(Пароль|пароль|ПАРОЛЬ)/ || h ~ /pass/) P=i
                else if (raw ~ /(Фамилия|фамилия|ФАМИЛИЯ)/ || h ~ /last|surname/) S=i
                else if (raw ~ /^(Имя|имя|ИМЯ)/ || h ~ /first|given/) G=i
                else if (raw ~ /(Почта|почта|ПОЧТА)/ || h ~ /mail/) M=i
                else if (raw ~ /(Телефон|телефон|ТЕЛЕФОН)/ || h ~ /phone|tel/) T=i
                else if (raw ~ /(Отдел|отдел|Подразделение|подразделение)/ || h ~ /depart/) D=i
                else if (raw ~ /(Должность|должность)/ || h ~ /title|job/) J=i
            }
            if (L) next
            L=1; P=2
        }
        { gsub(/\r|"/,""); if (col(L) != "") print col(L), col(P), col(G), col(S), col(M), col(T), col(D), col(J) }
    ' "$CSV" | while IFS=$'\037' read -r u pw g sn m t d j; do
        if [ -z "$pw" ]; then pw="$PASS"; fi
        if samba-tool user show "$u" >/dev/null 2>&1; then continue; fi
        args=()
        if [ -n "$g" ]; then args+=(--given-name="$g"); fi
        if [ -n "$sn" ]; then args+=(--surname="$sn"); fi
        if [ -n "$m" ]; then args+=(--mail-address="$m"); fi
        if [ -n "$t" ]; then args+=(--telephone-number="$t"); fi
        if [ -n "$d" ]; then args+=(--department="$d"); fi
        if [ -n "$j" ]; then args+=(--job-title="$j"); fi
        if samba-tool user create "$u" "$pw" "${args[@]}"; then log "импортирован $u"; else warn "не удалось создать $u"; fi
    done
else
    log "users.csv не найден — импорт пропущен (hquser1..5 созданы выше)"
fi

# sudo для группы hq: cat, grep, id
CMDS="$(command -v cat), $(command -v grep), $(command -v id)"
SUDO_TMP=$(mktemp)
printf '%%hq ALL=(ALL) NOPASSWD: %s\n%%DEMO\\\\hq ALL=(ALL) NOPASSWD: %s\n' "$CMDS" "$CMDS" > "$SUDO_TMP"
if ! visudo -cf "$SUDO_TMP" >/dev/null 2>&1; then
    printf '%%hq ALL=(ALL) NOPASSWD: %s\n' "$CMDS" > "$SUDO_TMP"
fi
install -m 440 "$SUDO_TMP" /etc/sudoers.d/hq
rm -f "$SUDO_TMP"
visudo -cf /etc/sudoers.d/hq >/dev/null || die "/etc/sudoers.d/hq содержит ошибки"

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

# образы из Additional.iso (site_latest -> testapp, mariadb_latest -> db)
DOCKER_DIR=$(find_extra d docker || true)
if [ -n "$DOCKER_DIR" ]; then
    for f in "$DOCKER_DIR"/*.tar; do
        if [ -f "$f" ]; then log "docker load < $f"; docker load -i "$f" || warn "не удалось загрузить $f"; fi
    done
fi
for pat in 'site_latest*' 'mariadb_latest*'; do
    f=$(find_extra f "$pat" || true)
    if [ -n "$f" ] && [ -f "$f" ]; then log "docker load < $f"; docker load -i "$f" || warn "не удалось загрузить $f"; fi
done

SITE_IMG="${SITE_IMAGE:-$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -iE '(^|/)site[:_-]' | head -n1 || true)}"
DB_IMG="${DB_IMAGE:-$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -iE '(^|/)mariadb[:_-]' | head -n1 || true)}"
if [ -z "$DB_IMG" ]; then
    warn "образ mariadb не найден — загружаю mariadb:latest"
    docker pull mariadb:latest || die "нет образа mariadb (положите Additional.iso или задайте DB_IMAGE)"
    DB_IMG=mariadb:latest
fi
if [ -z "$SITE_IMG" ]; then
    warn "образ site (site_latest) не найден — запускаю nginx:alpine как заглушку testapp"
    docker pull nginx:alpine || die "нет образа site (положите Additional.iso или задайте SITE_IMAGE)"
    SITE_IMG=nginx:alpine
fi
log "образы: site=$SITE_IMG, db=$DB_IMG"

docker network create testnet >/dev/null 2>&1 || true
docker rm -f testapp db >/dev/null 2>&1 || true
docker run -d --name db --network testnet --restart unless-stopped \
    -e MYSQL_ROOT_PASSWORD="$PASS" -e MYSQL_DATABASE=testdb \
    -e MYSQL_USER=testc -e MYSQL_PASSWORD="$PASS" \
    -v testdb_data:/var/lib/mysql "$DB_IMG"
PORT_IN=$(docker image inspect -f '{{range $p,$_ := .Config.ExposedPorts}}{{println $p}}{{end}}' "$SITE_IMG" 2>/dev/null | head -n1 | cut -d/ -f1)
PORT_IN="${TESTAPP_PORT_IN:-${PORT_IN:-80}}"
log "Запуск testapp: 8080 -> $PORT_IN"
docker run -d --name testapp --network testnet --restart unless-stopped -p 8080:"$PORT_IN" \
    -e DB_TYPE=maria -e DB_HOST=db -e DB_PORT=3306 -e DB_NAME=testdb \
    -e DB_USER=testc -e DB_PASS="$PASS" -e DB_PASSWORD="$PASS" "$SITE_IMG"
sleep 5
if curl -fsS -m 5 http://127.0.0.1:8080/ >/dev/null 2>&1; then log "testapp отвечает на :8080"; else warn "testapp пока не отвечает на :8080"; fi

# ----------------------------------------------------------- 4. Ansible ------
pkg ansible
pkg_try sshpass || true
mkdir -p /etc/ansible
write_file /etc/ansible/ansible.cfg <<'EOF'
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
interpreter_python = auto_silent
EOF
write_file /etc/ansible/hosts 640 <<'EOF'
[servers]
hq-srv ansible_host=192.168.100.2 ansible_user=sshuser
hq-cli ansible_host=192.168.200.2 ansible_user=sshuser

[routers]
hq-rtr ansible_host=192.168.100.1 ansible_user=net_admin
br-rtr ansible_host=192.168.1.1 ansible_user=net_admin

[all:vars]
ansible_port=2026
ansible_password=P@ssword
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
ansible_python_interpreter=auto_silent
EOF
write_file /etc/ansible/playbook.yml <<'EOF'
---
- name: Проверка доступности узлов
  hosts: all
  gather_facts: false
  tasks:
    - name: Ping
      ansible.builtin.ping:
EOF
if ansible all -m ping; then log "Ansible: все узлы отвечают"; else warn "Ansible: не все узлы доступны (проверьте, что остальные скрипты уже выполнены)"; fi

# ------------------------------------------------------------- 5. SSH --------
add_admin sshuser 2026
ssh_setup 2026
sshd_set MaxAuthTries 2
sshd_reload
rsyslog_client

echo "=== br-srv.sh configured successfully ==="
