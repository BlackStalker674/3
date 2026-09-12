#!/bin/bash
# HQ-SRV
# rsyslog_server.sh — приём syslog от HQ-RTR, BR-RTR, BR-SRV; фильтр >= warning; /opt/<host>/syslog.log
set -e

echo ">>> [1/3] Установка rsyslog"
apt-get update -y
apt-get install -y -q rsyslog logrotate

echo ">>> [2/3] Конфигурация приёма логов по сети"
cat > /etc/rsyslog.d/remote-logs.conf <<'EOF'
# Приём по UDP и TCP порту 514 от узлов сети au-team.irpo
module(load="imudp")
input(type="imudp" port="514")

module(load="imtcp")
input(type="imtcp" port="514")

# Шаблон пути: /opt/<имя-хоста-отправителя>/syslog.log
$template RemoteHostLog,"/opt/%HOSTNAME%/syslog.log"

# Разрешённые отправители: HQ-RTR, BR-RTR, BR-SRV
if ( $fromhost-ip == '10.10.10.1' or \
     $fromhost-ip == '10.20.10.1' or \
     $fromhost-ip == '10.20.10.2' ) and \
   $syslogseverity <= 4 then {
    action(type="omfile" dynaFile="RemoteHostLog")
    stop
}
EOF

mkdir -p /opt/hq-rtr /opt/br-rtr /opt/br-srv
chown syslog:adm /opt/hq-rtr /opt/br-rtr /opt/br-srv 2>/dev/null || true

echo ">>> [3/4] Конфигурация ротации логов (/etc/logrotate.d/remote-logs)"
cat > /etc/logrotate.d/remote-logs <<'EOF'
/opt/hq-rtr/syslog.log
/opt/br-rtr/syslog.log
/opt/br-srv/syslog.log
{
    weekly
    minsize 10M
    compress
    rotate 8
    missingok
    notifempty
    delaycompress
    create 0640 syslog adm
    postrotate
        systemctl kill -s HUP rsyslog.service 2>/dev/null || true
    endscript
}
EOF

echo ">>> [4/4] Запуск rsyslog"
systemctl enable --now rsyslog
systemctl restart rsyslog

echo "==================================================================="
echo " Приём удалённых логов настроен: UDP/TCP 514, приоритет >= warning"
echo " Файлы: /opt/<hostname>/syslog.log"
echo "==================================================================="
