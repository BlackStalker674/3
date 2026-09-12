#!/bin/bash
# HQ-CLI
# 01_check_auth_cli.sh — проверка авторизации импортированных пользователей (Kerberos/локально)
set -e

DOMAIN="au-team.irpo"
REALM="AU-TEAM.IRPO"
TEST_USER="${1:-}"
TEST_PASS="${2:-}"

if [ -z "${TEST_USER}" ]; then
    echo "Использование: $0 <username> [password]"
    exit 1
fi

echo ">>> [1/3] Проверка разрешения имени пользователя через DNS/NSS"
getent passwd "${TEST_USER}" && echo "[OK] NSS видит пользователя ${TEST_USER}" \
    || echo "[FAIL] NSS не видит пользователя ${TEST_USER}"

echo ">>> [2/3] Проверка Kerberos-аутентификации (kinit)"
if command -v kinit &>/dev/null; then
    if [ -n "${TEST_PASS}" ]; then
        echo "${TEST_PASS}" | kinit "${TEST_USER}@${REALM}" && \
            echo "[OK] kinit: билет TGT получен для ${TEST_USER}@${REALM}" || \
            echo "[FAIL] kinit: не удалось получить билет"
        klist
        kdestroy 2>/dev/null || true
    else
        echo "Пароль не передан — выполните вручную: kinit ${TEST_USER}@${REALM}"
    fi
else
    echo "[FAIL] kinit не установлен (пакет krb5-clients / krb5-workstation)"
fi

echo ">>> [3/3] Проверка входа под пользователем (su)"
su - "${TEST_USER}" -c "whoami" && echo "[OK] su: вход под ${TEST_USER} выполнен успешно" \
    || echo "[FAIL] su: вход под ${TEST_USER} не выполнен"

echo "==================================================================="
echo " Проверка авторизации ${TEST_USER}@${DOMAIN} завершена"
echo "==================================================================="
