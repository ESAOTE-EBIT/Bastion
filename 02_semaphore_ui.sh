#!/bin/bash

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║      Installazione Ansible Semaphore UI + Nginx (SSL)         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo

# Deve essere eseguito come root
if [ "$EUID" -ne 0 ]; then
  echo "Questo script deve essere eseguito come root." >&2
  exit 1
fi

# === CONFIGURAZIONE INIZIALE ===
echo "=== CONFIGURAZIONE PARAMETRI ==="
echo

# --- Password Semaphore ---
if [[ -z "${SECURE_PASS}" ]]; then
    read -srp "Inserisci password SECURE_PASS (min 8 caratteri): " SECURE_PASS
    echo
fi

if [[ ${#SECURE_PASS} -lt 8 ]]; then
    echo "Errore: SECURE_PASS troppo corta (minimo 8 caratteri)."
    exit 1
fi

SEMAPHORE_PASS="$SECURE_PASS"

# --- Utente Semaphore ---
read -rp "Utente Semaphore [ebit]: " SEMAPHORE_USER
SEMAPHORE_USER=${SEMAPHORE_USER:-ebit}

# --- Email Semaphore ---
read -rp "Email amministratore [michele.agostinelli@Ebit.com]: " SEMAPHORE_EMAIL
SEMAPHORE_EMAIL=${SEMAPHORE_EMAIL:-michele.agostinelli@Ebit.com}

# --- Dominio/Hostname Nginx ---
read -rp "Dominio per Nginx (es. semaphore.local, example.com) [semaphore.local]: " NGINX_DOMAIN
NGINX_DOMAIN=${NGINX_DOMAIN:-semaphore.local}

# --- Parametri SSL Certificate ---
read -rp "Paese (C) [IT]: " CERT_COUNTRY
CERT_COUNTRY=${CERT_COUNTRY:-IT}

read -rp "Provincia/Stato (ST) [Genova]: " CERT_STATE
CERT_STATE=${CERT_STATE:-Genova}

read -rp "Città (L) [Genova]: " CERT_CITY
CERT_CITY=${CERT_CITY:-Genova}

read -rp "Organizzazione (O) [Ebit]: " CERT_ORG
CERT_ORG=${CERT_ORG:-Ebit}

# --- Riepilogo configurazione ---
echo
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    RIEPILOGO CONFIGURAZIONE                   ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo "Utente Semaphore:        $SEMAPHORE_USER"
echo "Email Admin:             $SEMAPHORE_EMAIL"
echo "Dominio Nginx:           $NGINX_DOMAIN"
echo "Certificato SSL:"
echo "  - Paese (C):           $CERT_COUNTRY"
echo "  - Provincia (ST):      $CERT_STATE"
echo "  - Città (L):           $CERT_CITY"
echo "  - Organizzazione (O):  $CERT_ORG"
echo
read -rp "Continuo con questa configurazione? [s/N] " CONFIRM
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
    echo "Installazione annullata."
    exit 0
fi
echo

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
 tar xz-utils wget gnupg openssl vim sudo expect tmux tinyproxy \
 nginx

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

SEMAPHORE_PORT=3000
SEMAPHORE_CONF="/etc/semaphore/config.json"
SEMAPHORE_PLAYBOOKS="/home/$SEMAPHORE_USER/playbooks"

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
  "cookie_encryption": "'"$(openssl rand -base64 24)"'",
  "access_key_encryption": "'"$(openssl rand -base64 24)"'",
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

# === NGINX con Certificato Self-Signed ===
echo
echo "Creazione certificato self-signed per nginx..."
NGINX_CERT_DIR="/etc/nginx/certs"
NGINX_KEY="$NGINX_CERT_DIR/semaphore.key"
NGINX_CRT="$NGINX_CERT_DIR/semaphore.crt"

mkdir -p "$NGINX_CERT_DIR"

# Genera chiave privata e certificato self-signed
openssl req -x509 -newkey rsa:4096 -keyout "$NGINX_KEY" -out "$NGINX_CRT" \
  -days 365 -nodes \
  -subj "/C=$CERT_COUNTRY/ST=$CERT_STATE/L=$CERT_CITY/O=$CERT_ORG/CN=$NGINX_DOMAIN"

chmod 600 "$NGINX_KEY"
chmod 644 "$NGINX_CRT"

echo "✓ Certificato creato:"
echo "  Chiave: $NGINX_KEY"
echo "  Certificato: $NGINX_CRT"
echo "  Dominio: $NGINX_DOMAIN"

# Disabilita default site
rm -f /etc/nginx/sites-enabled/default

# Crea file di configurazione nginx reverse proxy per Semaphore UI
cat <<'EOF' > /etc/nginx/sites-available/semaphore
server {
  listen 443 ssl;
  server_name  NGINX_DOMAIN_PLACEHOLDER;
  # add Strict-Transport-Security to prevent man in the middle attacks
  add_header Strict-Transport-Security "max-age=31536000" always;
  # SSL
  ssl_certificate /etc/nginx/certs/semaphore.crt;
  ssl_certificate_key /etc/nginx/certs/semaphore.key;
  # Recommendations from 
  # https://raymii.org/s/tutorials/Strong_SSL_Security_On_nginx.html
  ssl_protocols TLSv1.1 TLSv1.2;
  ssl_ciphers 'EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH';
  ssl_prefer_server_ciphers on;
  ssl_session_cache shared:SSL:10m;
  # required to avoid HTTP 411: see Issue #1486 
  # (https://github.com/docker/docker/issues/1486)
  chunked_transfer_encoding on;
  location / {
    proxy_pass http://127.0.0.1:3000/;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_buffering off;
    proxy_request_buffering off;
  }
  location /api/ws {
    proxy_pass http://127.0.0.1:3000/api/ws;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Origin "";
  }
}
EOF

# Sostituisce il placeholder con il dominio reale
sed -i "s/NGINX_DOMAIN_PLACEHOLDER/$NGINX_DOMAIN/g" /etc/nginx/sites-available/semaphore

# Crea anche il redirect HTTP → HTTPS
cat <<EOF > /etc/nginx/sites-available/semaphore-http
server {
    listen 80;
    server_name $NGINX_DOMAIN;
    return 301 https://\$server_name\$request_uri;
}
EOF

# Abilita i siti
ln -sf /etc/nginx/sites-available/semaphore /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/semaphore-http /etc/nginx/sites-enabled/

# Test configurazione nginx
if nginx -t; then
    echo "✓ Configurazione nginx valida"
    systemctl enable --now nginx
else
    echo "✗ Errore nella configurazione nginx - Verifica il file"
    exit 1
fi

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
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║               INSTALLAZIONE COMPLETATA CON SUCCESSO!           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo
echo "Accesso a Semaphore UI:"
echo "  URL: https://$NGINX_DOMAIN"
echo "  Utente: $SEMAPHORE_USER"
echo "  Email: $SEMAPHORE_EMAIL"
echo
echo "Certificato SSL:"
echo "  Tipo: Self-Signed"
echo "  Chiave: /etc/nginx/certs/semaphore.key"
echo "  Certificato: /etc/nginx/certs/semaphore.crt"
echo
echo "⚠️  NOTA: Acceptare l'avviso del certificato self-signed nel browser"
echo