#!/bin/bash
# HQ-CLI
# ca.sh — импорт корневого сертификата AU-TEAM CA в системное хранилище доверия
set -e

CA_URL="http://hq-srv.au-team.irpo/pki/au-team-ca.crt"
CA_FILE="/usr/share/ca-certificates/au-team-ca.crt"
# Альтернативный путь для RPM-дистрибутивов (ALT/RHEL-подобные):
CA_FILE_RPM="/etc/pki/ca-trust/source/anchors/au-team-ca.crt"

echo ">>> [1/3] Загрузка корневого сертификата с HQ-SRV"
mkdir -p "$(dirname "${CA_FILE}")" "$(dirname "${CA_FILE_RPM}")" 2>/dev/null || true
curl -fsSL "${CA_URL}" -o "${CA_FILE_RPM}" || curl -fsSL "${CA_URL}" -o "${CA_FILE}"

echo ">>> [2/3] Добавление сертификата в системное хранилище"
if command -v update-ca-trust &>/dev/null; then
    cp "${CA_FILE_RPM}" /etc/pki/ca-trust/source/anchors/au-team-ca.crt 2>/dev/null || true
    update-ca-trust extract
elif command -v update-ca-certificates &>/dev/null; then
    cp "${CA_FILE_RPM}" "${CA_FILE}" 2>/dev/null || true
    update-ca-certificates
else
    echo "[ПРЕДУПРЕЖДЕНИЕ] Не найдена утилита update-ca-trust/update-ca-certificates — добавьте сертификат вручную"
fi

echo ">>> [3/3] Проверка доверия к сертификату web.au-team.irpo"
openssl s_client -connect web.au-team.irpo:443 -CAfile "${CA_FILE_RPM}" </dev/null 2>/dev/null \
    | grep -q "Verify return code: 0" \
    && echo "[OK] Сертификат web.au-team.irpo проходит проверку доверия" \
    || echo "[FAIL] Сертификат web.au-team.irpo НЕ проходит проверку доверия"

echo "Корневой сертификат AU-TEAM CA добавлен в доверенное хранилище HQ-CLI."
