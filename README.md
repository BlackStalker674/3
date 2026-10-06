1. HQ-SRV: hq-srv-rsyslog.sh. Сервер логов должен работать раньше клиентов.
2. HQ-RTR и BR-RTR: hq-rtr.sh и br-rtr.sh, один за другим без паузы. Пока второй роутер не настроен, туннель между ними не поднимется, и OSPF в первом скрипте покажет пустой список соседей. Это нормально. После второго скрипта проверьте vtysh -c 'show ip ospf neighbor' и ipsec statusall.
3. BR-SRV: br-srv-rsyslog.sh. Он отправляет логи через туннель, поэтому только после шага 2.
4. HQ-SRV: hq-srv-cups.sh, hq-srv-fail2ban.sh, hq-srv-monitoring.sh. Они независимы друг от друга. cups нужен раньше hq-cli.sh.
5. HQ-SRV: hq-srv-ca.sh. Он кладёт ключи на ISP и ca.cer на HQ-CLI, поэтому HQ-CLI и ISP должны быть включены, а isp.sh и hq-cli.sh из модуля 2 уже выполнены (нужны root по SSH на ISP и sshuser на порту 2026 на HQ-CLI).
6. ISP: isp-https.sh, после шага 5.
7. HQ-CLI: hq-cli.sh, после шагов 4 и 5 (нужны принтер и ca.cer).
8. BR-SRV: br-srv-users.sh и br-srv-inventory.sh. Для второго нужен доступ по SSH к HQ-SRV и HQ-CLI, то есть шаг 2 уже должен быть выполнен.
