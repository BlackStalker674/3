#!/bin/bash
# HQ-SRV
# users.sh — импорт учётных записей из users.csv (Additional.iso) в домен au-team.irpo
set -e

ISO_DEV="/dev/sr1"                 # устройство с Additional.iso (уточнить: sr0/sr1)
ISO_MOUNT="/media/iso"
USERS_CSV="${ISO_MOUNT}/users.csv"
DOMAIN="au-team.irpo"
LOG_FILE="/var/log/users_import.log"

mkdir -p "${ISO_MOUNT}"
touch "${LOG_FILE}"

echo ">>> [1/4] Монтирование Additional.iso"
if ! mountpoint -q "${ISO_MOUNT}"; then
    mount -o loop,ro "${ISO_DEV}" "${ISO_MOUNT}" 2>/dev/null || mount "${ISO_DEV}" "${ISO_MOUNT}"
fi

if [ ! -f "${USERS_CSV}" ]; then
    echo "ОШИБКА: файл ${USERS_CSV} не найден после монтирования ISO" | tee -a "${LOG_FILE}"
    exit 1
fi

echo ">>> [2/4] Парсинг users.csv (username;password;firstname;lastname)"
# Ожидаемый формат CSV (разделитель , или ; — определяется автоматически):
#   username,password,firstname,lastname
DELIM=","
head -n1 "${USERS_CSV}" | grep -q ";" && DELIM=";"

CREATED=0
SKIPPED=0
FAILED=0

# Пропускаем заголовок (если он есть) — определяем по наличию нечислового username в 1-й строке
FIRST_LINE=$(head -n1 "${USERS_CSV}")
if echo "${FIRST_LINE}" | grep -qi "username"; then
    TAIL_OPTS="tail -n +2"
else
    TAIL_OPTS="cat"
fi

echo ">>> [3/4] Создание учётных записей в домене ${DOMAIN}"
while IFS="${DELIM}" read -r USERNAME PASSWORD FIRSTNAME LASTNAME; do
    USERNAME=$(echo "${USERNAME}" | tr -d '\r' | xargs)
    PASSWORD=$(echo "${PASSWORD}" | tr -d '\r' | xargs)
    FIRSTNAME=$(echo "${FIRSTNAME}" | tr -d '\r' | xargs)
    LASTNAME=$(echo "${LASTNAME}" | tr -d '\r' | xargs)

    [ -z "${USERNAME}" ] && continue

    if id "${USERNAME}" &>/dev/null; then
        echo "[SKIP] ${USERNAME} уже существует" | tee -a "${LOG_FILE}"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    if useradd -m -c "${FIRSTNAME} ${LASTNAME}" -s /bin/bash "${USERNAME}"; then
        echo "${USERNAME}:${PASSWORD}" | chpasswd
        # Домен: samba-tool (если развёрнут Samba AD DC) — раскомментировать при наличии контроллера домена
        # samba-tool user create "${USERNAME}" "${PASSWORD}" \
        #     --given-name="${FIRSTNAME}" --surname="${LASTNAME}" \
        #     --userou="OU=Users,DC=au-team,DC=irpo"
        echo "[OK]   ${USERNAME} (${FIRSTNAME} ${LASTNAME}) создан" | tee -a "${LOG_FILE}"
        CREATED=$((CREATED+1))
    else
        echo "[FAIL] ${USERNAME} — ошибка создания" | tee -a "${LOG_FILE}"
        FAILED=$((FAILED+1))
    fi
done < <($TAIL_OPTS "${USERS_CSV}")

echo ">>> [4/4] Размонтирование ISO"
umount "${ISO_MOUNT}" 2>/dev/null || true

echo "==================================================================="
echo " Импорт пользователей завершён: создано=${CREATED} пропущено=${SKIPPED} ошибок=${FAILED}"
echo " Подробный лог: ${LOG_FILE}"
echo "==================================================================="
