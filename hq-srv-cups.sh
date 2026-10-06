#!/bin/bash
# HQ-SRV, модуль 3, п.5: принт-сервер CUPS с виртуальным PDF-принтером
apt-get update && apt-get install -y tzdata cups cups-pdf
systemctl enable --now cups

cupsctl --share-printers --remote-any
systemctl restart cups
sleep 2

PPD=$(lpinfo -m | grep -i 'cups-pdf' | head -1 | awk '{print $1}')
if [ -n "$PPD" ]; then
  lpadmin -p Cups-PDF -E -v cups-pdf:/ -m "$PPD"
else
  lpadmin -p Cups-PDF -E -v cups-pdf:/ -m raw
fi
lpadmin -p Cups-PDF -o printer-is-shared=true
cupsenable Cups-PDF
cupsaccept Cups-PDF

lpstat -p -v
