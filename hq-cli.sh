#!/bin/bash
# HQ-CLI, модуль 3: п.2 доверие корневому сертификату, п.5 принтер по умолчанию, п.10 каталог /backup
apt-get update && apt-get install -y tzdata cups

# ---- п.2: доверие CA ----
[ -f /home/sshuser/ca.cer ] || { echo "Нет /home/sshuser/ca.cer: сначала запустите hq-srv-ca.sh на HQ-SRV"; exit 1; }
install -m 644 /home/sshuser/ca.cer /etc/pki/ca-trust/source/anchors/au-team-ca.crt
update-ca-trust
echo "Если Яндекс Браузер всё равно ругается на сертификат, импортируйте ca.cer в его хранилище (Настройки - Безопасность - Сертификаты)"

# ---- п.5: сетевой PDF-принтер с HQ-SRV по умолчанию ----
systemctl enable --now cups
lpadmin -p HQ-PDF -E -v ipp://192.168.100.2:631/printers/Cups-PDF -m everywhere
lpadmin -d HQ-PDF
lpstat -p -d

# ---- п.10: каталог для узла хранилища резервных копий ----
mkdir -p /backup
