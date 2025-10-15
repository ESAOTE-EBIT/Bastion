#!/bin/bash
# vedi: https://computingforgeeks.com/install-semaphore-ansible-web-ui-on-ubuntu-debian/

echo "Installazione semaphore UI, premi un tasto per continuare"
read a

# Controllo se l'utente è root
if [ "$EUID" -ne 0 ]; then
  echo "Questo script deve essere eseguito come root." >&2
  exit 1
fi

if [[ -z "${SECURE_PASS}" || ${#SECURE_PASS} -lt 8 ]]; then
    echo "Errore: variabile SECURE_PASS non definita o troppo corta."
    echo "Esempio: export SECURE_PASS=miapassword"
    exit 1
fi
SEMAPHORE_PASS=$SECURE_PASS
# LOCALE
DEBIAN_FRONTEND=noninteractive apt update; apt install -y locales
sed -i 's/^# *it_IT.UTF-8 UTF-8/it_IT.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=it_IT.UTF-8

echo "LANG=it_IT.UTF-8
LANGUAGE=it_IT:it
LC_ALL=it_IT.UTF-8" > /etc/default/locale

export LANG=it_IT.UTF-8
export LANGUAGE=it_IT:it
export LC_ALL=it_IT.UTF-8

DEBIAN_FRONTEND=noninteractive apt full-upgrade -yq
DEBIAN_FRONTEND=noninteractive apt install -y ansible qemu-guest-agent vim curl sshpass openssh-server git tar xz-utils wget gnupg openssl vim sudo expect tmux tinyproxy

# Personalizzazione VIM
cat <<EOF > /etc/vim/vimrc.local
" This file loads the default vim options at the beginning and prevents
" that they are being loaded again later. All other options that will be set,
" are added, or overwrite the default settings. Add as many options as you
" whish at the end of this file.

" Load the defaults
source \$VIMRUNTIME/defaults.vim

" Prevent the defaults from being loaded again later, if the user doesn't
" have a local vimrc (~/.vimrc)
let skip_defaults_vim = 1

" Set more options (overwrites settings from /usr/share/vim/vim80/defaults.vim)
" Add as many options as you whish

" Set the mouse mode to 'r'
if has('mouse')
  set mouse=r
endif
EOF

su - ebit -c "ansible-galaxy collection install community.general community.proxmox"

DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server; systemctl enable --now mariadb

cat <<EOF > secure_mariadb.expect
#!/usr/bin/expect -f

set timeout 10

spawn mariadb-secure-installation

expect "Enter current password for root (enter for none):"
send "\r"

expect "Switch to unix_socket authentication"
send "n\r"

expect "Change the root password?"
send "Y\r"

expect "New password:"
send "$SECURE_PASS\r"

expect "Re-enter new password:"
send "$SECURE_PASS\r"

expect "Remove anonymous users?"
send "Y\r"

expect "Disallow root login remotely?"
send "Y\r"

expect "Remove test database and access to it?"
send "Y\r"

expect "Reload privilege tables now?"
send "Y\r"

expect eof
EOF

chmod +x secure_mariadb.expect
./secure_mariadb.expect

rm -f secure_mariadb.expect

mariadb <<EOF
CREATE DATABASE semaphore_db;
GRANT ALL PRIVILEGES ON semaphore_db.* TO semaphore_user@localhost IDENTIFIED BY '$(echo $SECURE_PASS)';
EOF

# === Scarica l'ultima versione di Semaphore ===
curl -L -s https://api.github.com/repos/ansible-semaphore/semaphore/releases/latest \
| grep "browser_download_url.*amd64.deb" \
| cut -d : -f 2,3 \
| tr -d \" \
| wget -qi -
dpkg -i semaphore*.deb

# === Variabili configurabili ===
SEMAPHORE_USER="ebit"
SEMAPHORE_EMAIL="michele.agostinelli@esaote.com"
SEMAPHORE_PORT=3000
SEMAPHORE_CONF="/etc/semaphore/config.json"
SEMAPHORE_PLAYBOOKS="/home/ebit/playbooks"

mkdir /etc/semaphore
chown -R ${SEMAPHORE_USER}: /etc/semaphore

echo '{
  "mysql": {
    "host": "127.0.0.1:3306",
    "user": "semaphore_user",
    "pass": "'"$SECURE_PASS"'",
    "name": "semaphore_db"
  },
  "dialect": "mysql",
  "port": "'"$SEMAPHORE_PORT"'",
  "cookie_hash": "'"$(openssl rand -base64 24)"'",
  "cookie_encryption": "'"$(openssl rand -base64 24)"'",
  "access_key_encryption": "'"$(openssl rand -base64 24)"'",
  "playbook_path": "'"$SEMAPHORE_PLAYBOOKS"'"
}' > "$SEMAPHORE_CONF"

semaphore user add --admin --login "$SEMAPHORE_USER" --name "$SEMAPHORE_USER" --email "$SEMAPHORE_EMAIL" --password "$SECURE_PASS" --config "$SEMAPHORE_CONF"

echo "[Unit]
Description=Ansible Semaphore
Documentation=https://docs.ansible-semaphore.com/
Wants=network-online.target
After=network-online.target
ConditionPathExists=/usr/bin/semaphore
ConditionPathExists=/etc/semaphore/config.json

[Service]
ExecStart=/usr/bin/semaphore server --config $SEMAPHORE_CONF
ExecReload=/bin/pkill -HUP semaphore
Restart=always
RestartSec=10s
User=$SEMAPHORE_USER
Group=$SEMAPHORE_USER

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/semaphore.service

systemctl daemon-reload
systemctl enable --now semaphore.service

# Pulizia VM
apt clean
# rm -rf /var/lib/apt/lists/*
# truncate -s 0 /var/log/*.log
# history -c
# dd if=/dev/zero of=/zero.fill bs=1M || true
# rm -f /zero.fill


# Generazione chiave SSH
su - ebit -c 'ssh-keygen -t rsa -b 4096 -f .ssh/id_rsa -N ""'
echo -e "\e[1;31mAttenzione: salvare in un posto sicuro la chiave PRIVATA generata\e[0m"
su - ebit -c 'ls .ssh/'
su - ebit -c 'cat .ssh/id_rsa'
echo "Copia e autorizza chiave pubblica sui server proxmox..."
su - ebit -c 'ssh-copy-id proxmox1'
