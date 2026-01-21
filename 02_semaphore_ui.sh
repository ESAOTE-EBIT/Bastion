#!/bin/bash

echo "Installazione semaphore UI, premi un tasto per continuare"
read -r a

# Deve essere eseguito come root
if [ "$EUID" -ne 0 ]; then
  echo "Questo script deve essere eseguito come root." >&2
  exit 1
fi

# === Richiesta SECURE_PASS ===
if [[ -z "${SECURE_PASS}" ]]; then
    read -srp "Inserisci password SECURE_PASS (min 8 caratteri): " SECURE_PASS
    echo
fi

if [[ ${#SECURE_PASS} -lt 8 ]]; then
    echo "Errore: SECURE_PASS troppo corta (minimo 8 caratteri)."
    exit 1
fi

SEMAPHORE_PASS="$SECURE_PASS"

# === Locale ===
DEBIAN_FRONTEND=noninteractive apt update; apt install -y locales
sed -i 's/^# *it_IT.UTF-8 UTF-8/it_IT.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=it_IT.UTF-8

export LANG=it_IT.UTF-8 LANGUAGE=it_IT:it LC_ALL=it_IT.UTF-8
timedatectl set-timezone Europe/Rome

DEBIAN_FRONTEND=noninteractive apt full-upgrade -yq
DEBIAN_FRONTEND=noninteractive apt install -y \
 ansible qemu-guest-agent vim curl sshpass openssh-server git \
 tar xz-utils wget gnupg openssl vim sudo expect tmux tinyproxy

# Config Vim minimal
cat <<EOF > /etc/vim/vimrc.local
source \$VIMRUNTIME/defaults.vim
let skip_defaults_vim = 1
if has('mouse')
  set mouse=r
endif
EOF

su - ebit -c "ansible-galaxy collection install community.general community.proxmox"

DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server
systemctl enable --now mariadb

# Configurazione MariaDB non-interattiva
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
GRANT ALL PRIVILEGES ON semaphore_db.* TO semaphore_user@localhost IDENTIFIED BY '${SECURE_PASS}';
EOF

# Install Semaphore
curl -L -s https://api.github.com/repos/ansible-semaphore/semaphore/releases/latest \
| grep "browser_download_url.*amd64.deb" \
| cut -d : -f 2,3 \
| tr -d \" \
| wget -qi -
dpkg -i semaphore*.deb

SEMAPHORE_USER="ebit"
SEMAPHORE_EMAIL="michele.agostinelli@esaote.com"
SEMAPHORE_PORT=3000
SEMAPHORE_CONF="/etc/semaphore/config.json"
SEMAPHORE_PLAYBOOKS="/home/ebit/playbooks"

mkdir -p /etc/semaphore
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
  "cookie_encryption": "'"$(openssl.rand -base64 24)"'",
  "access_key_encryption": "'"$(openssl.rand -base64 24)"'",
  "playbook_path": "'"$SEMAPHORE_PLAYBOOKS"'"
}' > "$SEMAPHORE_CONF"

semaphore user add --admin --login "$SEMAPHORE_USER" \
 --name "$SEMAPHORE_USER" \
 --email "$SEMAPHORE_EMAIL" \
 --password "$SECURE_PASS" \
 --config "$SEMAPHORE_CONF"

cat <<EOF > /etc/systemd/system/semaphore.service
[Unit]
Description=Ansible Semaphore
After=network-online.target
Requires=network-online.target

[Service]
ExecStart=/usr/bin/semaphore server --config $SEMAPHORE_CONF
Restart=always
RestartSec=10
User=$SEMAPHORE_USER
Group=$SEMAPHORE_USER

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now semaphore.service

apt clean

# === Generazione chiave SSH per ebit ===
if [[ ! -f /home/ebit/.ssh/id_rsa ]]; then
  su - ebit -c 'ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""'
fi

# === Copia chiavi SSH multi-host ===
echo
echo "Copia e autorizza la chiave pubblica di ebit sui server..."

mkdir -p /root/.ssh
chmod 700 /root/.ssh

EBIT_PUB_KEY="/home/ebit/.ssh/id_rsa.pub"

read -rp "Quanti host vuoi configurare? " NUM_HOST
if ! [[ "$NUM_HOST" =~ ^[0-9]+$ ]] || [ "$NUM_HOST" -le 0 ]; then
    echo "Numero di host non valido."
    exit 1
fi

declare -a HOSTS
for (( i=1; i<=NUM_HOST; i++ )); do
    read -rp "Host #$i (es. 10.31.0.46): " H
    HOSTS+=("$H")
done

read -rp "Utente remoto sugli host (default: ebit): " REMOTE_USER
REMOTE_USER=${REMOTE_USER:-ebit}

read -srp "Password di $REMOTE_USER sugli host: " REMOTE_PASS
echo

echo "Verrà copiata la chiave su:"
printf " - %s\n" "${HOSTS[@]}"
echo
read -rp "Confermi? [s/N] " C
[[ "$C" != "s" && "$C" != "S" ]] && exit 0

for H in "${HOSTS[@]}"; do
    echo ">>> Copia chiave su $H"
    TARGET="$REMOTE_USER@$H"
    sshpass -p "$REMOTE_PASS" ssh-copy-id -i "$EBIT_PUB_KEY" -o StrictHostKeyChecking=no "$TARGET"
done

echo
echo "Installazione completata!"
echo "Interfaccia Web di Semaphore sulla porta $SEMAPHORE_PORT"
