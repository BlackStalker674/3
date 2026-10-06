#!/bin/bash
# BR-SRV, модуль 3, п.1: импорт пользователей из users.csv (Additional.iso) в домен au-team.irpo
# Ожидаемый порядок столбцов (как в вашем user.sh): First Name;Last Name;Role;Phone;OU;Street;ZIP;City;Country;Password
# Проверьте заголовок файла: head -1 /mnt/users.csv
mount /dev/sr0 /mnt 2>/dev/null || true
CSV=$(find /mnt -maxdepth 1 -iname 'users.csv' | head -1)
[ -n "$CSV" ] || { echo "users.csv не найден в /mnt (Additional.iso подключён?)"; exit 1; }

sed 's/\r$//' "$CSV" > /root/users.csv
head -2 /root/users.csv

# Подразделения (OU)
tail -n +2 /root/users.csv | awk -F';' '{print $5}' | sort -u | while read -r ou; do
  [ -n "$ou" ] && samba-tool ou create "OU=$ou"
done

# Дополнительные атрибуты, для которых нет ключей в samba-tool user add
ldif_attr() { [ -n "$3" ] && printf -- '-\nreplace: %s\n%s: %s\n' "$1" "$1" "$3"; }

exec 3< <(tail -n +2 /root/users.csv)
while IFS=';' read -r -u 3 first last role phone ou street zip city country pass; do
  [ -z "$first" ] && continue
  user="${first,,}.${last,,}"

  samba-tool user add "$user" "$pass" \
    --given-name="$first" --surname="$last" \
    --job-title="$role" --telephone-number="$phone" \
    ${ou:+--userou="OU=$ou"}
  samba-tool user setexpiry "$user" --noexpiry

  dn=$(samba-tool user show "$user" --attributes=distinguishedName | sed -n 's/^distinguishedName: //p')
  {
    echo "dn: $dn"; echo "changetype: modify"
    echo "replace: description"; echo "description: $role"
    ldif_attr streetAddress x "$street"
    ldif_attr postalCode    x "$zip"
    ldif_attr l             x "$city"
    ldif_attr co            x "$country"
  } > /tmp/u.ldif
  ldbmodify -H ldap://127.0.0.1 -U 'Administrator%P@ssw0rd' /tmp/u.ldif || true
done

samba-tool user list | grep -vc hquser
