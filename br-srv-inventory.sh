#!/bin/bash
# BR-SRV, модуль 3, п.8: плейбук инвентаризации HQ-SRV и HQ-CLI; отчёты в /etc/ansible/PC-INFO/<имя>.yml
mount /dev/sr0 /mnt 2>/dev/null || true
mkdir -p /etc/ansible/PC-INFO

if ls /mnt/playbook/*.yml >/dev/null 2>&1; then
  cp /mnt/playbook/*.yml /etc/ansible/
  PB=$(ls /mnt/playbook/*.yml | head -1); PB=/etc/ansible/$(basename "$PB")
  # путь отчётов по заданию - PC-INFO
  sed -i 's#PC_INFO#PC-INFO#g' "$PB"
  echo "Плейбук из образа: $PB"
else
  PB=/etc/ansible/get_hostname.yml
  cat > $PB <<'EOF'
- name: Get_hostname
  hosts: hq-srv,hq-cli
  gather_facts: true
  tasks:
    - name: Create info directory
      file:
        path: /etc/ansible/PC-INFO
        state: directory
        mode: '0755'
      delegate_to: localhost
      run_once: true

    - name: Save hostname and ip
      copy:
        dest: /etc/ansible/PC-INFO/{{ ansible_hostname }}.yml
        content: |
          Hostname: {{ ansible_hostname }}
          IP_Address: {{ ansible_default_ipv4.address }}
      delegate_to: localhost
EOF
  echo "В образе плейбука нет, создан свой: $PB"
fi

cd /etc/ansible
ansible-playbook "$PB"
ls -l /etc/ansible/PC-INFO
cat /etc/ansible/PC-INFO/*.yml
