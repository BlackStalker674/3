#!/bin/bash
# HQ-SRV, модуль 3, п.6: сервер сбора логов rsyslog, каталог /opt/<имя машины>, ротация раз в неделю
apt-get update && apt-get install -y tzdata rsyslog logrotate

mkdir -p /opt

cat > /etc/rsyslog.d/server.conf <<'EOF'
module(load="imtcp")
input(type="imtcp" port="514")

template(name="PerHostFile" type="string" string="/opt/%HOSTNAME%/%PROGRAMNAME%.log")

# Только сообщения от других машин (сервер не является клиентом самому себе), приоритет warning и выше
if ($fromhost-ip != '127.0.0.1' and $syslogseverity <= 4) then {
	action(type="omfile" dynaFile="PerHostFile" dirCreateMode="0755" fileCreateMode="0644")
	stop
}
EOF

# Ротация: раз в неделю, со сжатием, не меньше 10 МБ, все логи в /opt и подкаталогах
cat > /etc/logrotate.d/opt-logs <<'EOF'
/opt/*.log /opt/*/*.log /opt/*/*/*.log {
    weekly
    minsize 10M
    compress
    missingok
    notifempty
    sharedscripts
    postrotate
        /bin/systemctl restart rsyslog.service > /dev/null 2>&1 || true
    endscript
}
EOF

systemctl enable --now rsyslog
systemctl restart rsyslog
ss -tlnp | grep 514
