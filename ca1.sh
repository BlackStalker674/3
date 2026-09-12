#!/bin/bash
# HQ-SRV
# ca1.sh — локальный CA (OpenSSL + ГОСТ engine), выпуск сертификатов сроком на 30 дней
set -e

CA_DIR="/etc/pki/au-team-ca"
CA_KEY="${CA_DIR}/private/ca.key"
CA_CERT="${CA_DIR}/certs/ca.crt"
CERT_DAYS=30
GOST_CNF="${CA_DIR}/gost.cnf"

echo ">>> [1/6] Установка OpenSSL и ГОСТ-модуля"
apt-get update -y
apt-get install -y -q openssl openssl-gost-engine libgost-engine || \
apt-get install -y -q openssl gost-engine || \
apt-get install -y -q openssl engine-gost

GOST_ENGINE_SO=$(find / -iname "libgost.so*" 2>/dev/null | head -n1)
GOST_AVAILABLE=0
[ -n "${GOST_ENGINE_SO}" ] && GOST_AVAILABLE=1

mkdir -p "${CA_DIR}"/{private,certs,newcerts,csr}
chmod 700 "${CA_DIR}/private"
touch "${CA_DIR}/index.txt"
echo 1000 > "${CA_DIR}/serial"

echo ">>> [2/6] Конфигурация OpenSSL с поддержкой ГОСТ (engine section)"
cat > "${GOST_CNF}" <<EOF
openssl_conf = openssl_def

[openssl_def]
engines = engine_section

[engine_section]
gost = gost_section

[gost_section]
engine_id = gost
dynamic_path = ${GOST_ENGINE_SO:-/usr/lib64/engines-3/gost.so}
default_algorithms = ALL
CRYPT_PARAMS = id-Gost28147-89-CryptoPro-A-ParamSet

[ req ]
default_bits       = 256
default_md         = md_gost12_256
distinguished_name = req_distinguished_name
prompt             = no

[ req_distinguished_name ]
C  = RU
ST = Moscow
L  = Moscow
O  = AU-TEAM
CN = AU-TEAM Root CA
EOF

export OPENSSL_CONF="${GOST_CNF}"

echo ">>> [3/6] Генерация корневого CA"
if [ ! -f "${CA_KEY}" ]; then
    if [ "${GOST_AVAILABLE}" -eq 1 ]; then
        openssl req -x509 -new -engine gost \
            -newkey gost2012_256 -pkeyopt paramset:A \
            -nodes -days 3650 \
            -keyout "${CA_KEY}" -out "${CA_CERT}" \
            -subj "/C=RU/ST=Moscow/L=Moscow/O=AU-TEAM/CN=AU-TEAM Root CA"
    else
        echo "[ПРЕДУПРЕЖДЕНИЕ] ГОСТ-движок не найден — CA выпущен на RSA (запасной вариант)"
        openssl req -x509 -new -nodes -days 3650 -newkey rsa:2048 \
            -keyout "${CA_KEY}" -out "${CA_CERT}" \
            -subj "/C=RU/ST=Moscow/L=Moscow/O=AU-TEAM/CN=AU-TEAM Root CA"
    fi
fi

echo ">>> [4/6] Функция выпуска сертификата (срок действия: ${CERT_DAYS} дней)"
issue_cert() {
    local CN="$1"
    local KEY="${CA_DIR}/private/${CN}.key"
    local CSR="${CA_DIR}/csr/${CN}.csr"
    local CRT="${CA_DIR}/certs/${CN}.crt"

    if [ "${GOST_AVAILABLE}" -eq 1 ]; then
        openssl req -new -engine gost -newkey gost2012_256 -pkeyopt paramset:A \
            -nodes -keyout "${KEY}" -out "${CSR}" \
            -subj "/C=RU/ST=Moscow/L=Moscow/O=AU-TEAM/CN=${CN}"
    else
        openssl req -new -nodes -newkey rsa:2048 \
            -keyout "${KEY}" -out "${CSR}" \
            -subj "/C=RU/ST=Moscow/L=Moscow/O=AU-TEAM/CN=${CN}"
    fi

    openssl x509 -req -in "${CSR}" \
        -CA "${CA_CERT}" -CAkey "${CA_KEY}" -CAcreateserial \
        -out "${CRT}" -days "${CERT_DAYS}" -sha256

    echo "    Выпущен сертификат: ${CRT} (действителен ${CERT_DAYS} дней)"
}

echo ">>> [5/6] Выпуск сертификатов для web.au-team.irpo и docker.au-team.irpo"
issue_cert "web.au-team.irpo"
issue_cert "docker.au-team.irpo"

echo ">>> [6/6] Публикация корневого сертификата для клиентов"
mkdir -p /var/www/pki
cp "${CA_CERT}" /var/www/pki/au-team-ca.crt

echo "==================================================================="
echo " CA готов. Корневой сертификат: ${CA_CERT}"
echo " Раздача клиентам: http://hq-srv.au-team.irpo/pki/au-team-ca.crt"
echo "==================================================================="
