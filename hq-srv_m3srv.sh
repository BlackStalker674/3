#!/bin/bash
# HQ-SRV
# hq-srv_m3srv.sh — установка CUPS и публикация виртуального PDF-принтера в сеть
set -e

PRINTER_NAME="AU-TEAM-PDF"
CUPS_PDF_DIR="/var/spool/cups-pdf"

echo ">>> [1/5] Установка CUPS и cups-pdf"
apt-get update -y
apt-get install -y -q cups cups-pdf

echo ">>> [2/5] Настройка удалённого администрирования и публикации в сеть"
mkdir -p /etc/cups
cp /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak 2>/dev/null || true

sed -i \
    -e 's/^Listen localhost:631/Port 631/' \
    -e 's/^Browsing .*/Browsing On/' \
    /etc/cups/cupsd.conf

grep -q "^Port 631" /etc/cups/cupsd.conf || echo "Port 631" >> /etc/cups/cupsd.conf
grep -q "^Browsing On" /etc/cups/cupsd.conf || echo "Browsing On" >> /etc/cups/cupsd.conf
grep -q "BrowseLocalProtocols" /etc/cups/cupsd.conf || echo "BrowseLocalProtocols dnssd" >> /etc/cups/cupsd.conf

cat >> /etc/cups/cupsd.conf <<'EOF'

<Location />
  Order allow,deny
  Allow from 10.10.0.0/16
  Allow from 10.20.0.0/16
  Allow from 127.0.0.1
</Location>

<Location /admin>
  Order allow,deny
  Allow from 10.10.0.0/16
  Allow from 127.0.0.1
</Location>
EOF

echo ">>> [3/5] Настройка виртуального PDF-принтера"
mkdir -p "${CUPS_PDF_DIR}"
chmod 1777 "${CUPS_PDF_DIR}"

systemctl enable --now cups
systemctl restart cups
sleep 2

echo ">>> [4/5] Регистрация принтера ${PRINTER_NAME} в CUPS"
lpadmin -p "${PRINTER_NAME}" \
    -E \
    -v "cups-pdf:/" \
    -m "CUPS-PDF.ppd" \
    -D "Виртуальный PDF-принтер AU-TEAM" \
    -L "HQ-SRV" 2>/dev/null || \
lpadmin -p "${PRINTER_NAME}" -E -v "cups-pdf:/" -m everywhere

cupsenable "${PRINTER_NAME}"
cupsaccept "${PRINTER_NAME}"
lpadmin -d "${PRINTER_NAME}"

echo ">>> [5/5] Публикация принтера в сеть (общий доступ)"
cupsctl --share-printers
lpadmin -p "${PRINTER_NAME}" -o printer-is-shared=true

echo "==================================================================="
echo " Принтер ${PRINTER_NAME} опубликован: ipp://hq-srv.au-team.irpo:631/printers/${PRINTER_NAME}"
echo " Веб-интерфейс CUPS: http://hq-srv.au-team.irpo:631"
echo "==================================================================="
