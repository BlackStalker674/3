#!/bin/bash
# HQ-SRV, модуль 3, п.2: центр сертификации на отечественных алгоритмах (ГОСТ Р 34.10-2012), срок 30 дней
ISP_IP=172.16.1.1
ISP_PASS=''                   # пароль root на ISP; если пусто, scp спросит пароль сам
HQ_CLI_IP=192.168.200.2       # адрес HQ-CLI, который он получил по DHCP

apt-get update && apt-get install -y tzdata openssl-gost-engine sshpass
control openssl-gost enabled

mkdir -p /root/ca && cd /root/ca

# Корневой сертификат (CA)
openssl genpkey -algorithm gost2012_256 -pkeyopt paramset:TCB -out ca.key
openssl req -new -x509 -md_gost12_256 -days 30 -key ca.key -out ca.cer \
  -subj "/C=RU/O=AU-TEAM/CN=AU-TEAM Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"

# Сертификаты веб-серверов (с SAN, иначе браузер выдаст предупреждение)
for n in web docker; do
  openssl genpkey -algorithm gost2012_256 -pkeyopt paramset:A -out $n.au-team.irpo.key
  openssl req -new -md_gost12_256 -key $n.au-team.irpo.key -out $n.au-team.irpo.csr \
    -subj "/C=RU/O=AU-TEAM/CN=$n.au-team.irpo"
  openssl x509 -req -in $n.au-team.irpo.csr -CA ca.cer -CAkey ca.key -CAcreateserial \
    -out $n.au-team.irpo.cer -days 30 \
    -extfile <(printf 'subjectAltName=DNS:%s.au-team.irpo\nextendedKeyUsage=serverAuth\n' $n)
done

openssl x509 -in web.au-team.irpo.cer -noout -subject -issuer -dates

SSHO="-o StrictHostKeyChecking=no"
P=""; [ -n "$ISP_PASS" ] && P="sshpass -p $ISP_PASS"

# Ключи и сертификаты на ISP (для nginx)
$P scp $SSHO web.au-team.irpo.key web.au-team.irpo.cer docker.au-team.irpo.key docker.au-team.irpo.cer root@$ISP_IP:/root/

# Корневой сертификат на HQ-CLI (доверие); sshuser создан скриптом модуля 2
sshpass -p 'P@ssw0rd' scp $SSHO -P 2026 ca.cer sshuser@$HQ_CLI_IP:/home/sshuser/ca.cer
