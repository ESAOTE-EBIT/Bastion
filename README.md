# Bastion
Repository per creazione Bastion Host


## Prerequisiti

### Password e chiavi
Per la gestione dell'ambiente sarà necessario definire una password per l'utente amministratore e una coppia di chiavi privata/pubblica. 
Queste due informazioni andranno custodite in maniera sicura (es: Password Manager).

### Ambiente proxmox
Occorre avere un cluster proxmox installato e funzionante.

#### Creazione utente (su proxmox) con permessi di amministratore
a. Aprire la console web di proxmox (porta 8006) ed effettuare login
b. Accedere alla shell dei 3 (o più) nodi fisici e dare i comandi:
```bash
    adduser --system --group --shell /bin/bash --home /home/ebit ebit
    usermod -aG sudo ebit
    echo "ebit ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/ebit
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config 
    systemctl enable ssh
    systemctl restart  ssh
    sed -i 's/^# *it_IT.UTF-8 UTF-8/it_IT.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    update-locale LANG=it_IT.UTF-8
    passwd ebit
```

Accedere in console (su uno dei nodi del cluster proxmox) e digitare i comandi degli script 01 e 02 presenti in questo repository come utente root.
Prestare attenzione all'indirizzamento di rete del server bastion.

Verrà create la VM bastion attraverso gli script presenti.


### Vmware
Scaricare immagine ova di ubuntu LTS da qui: https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.ova, oppure se vSphere è collegato ad internet è possibile effettuare il deploy del server direttamente con il link indicato in precedenza.

Importare ova secondo la procedura guidata, fino alla schermata in cui, tra le altre opzioni, verrà rochiesta l'inserimento del campo userdata.
Questo campo contiene i paramentri cloud-init in formato base64. Personalizzaere i parametri del file cloud-init.yml usando il template presente in questo repository.

Generare la versione base64 del file preparato:

_Linux_: ``` base64 -w0 userdata.yml > userdata.b64 ```
_Windows_: ``` certutil -encode userdata.yml userdata.b64 ```

Inserire il valore generato nel campo _userdata_ e completare il deploy del server.

**Inserire schermate di esempio**

### Setup ambiente

#### Installazione SemaphoreUI
Collegarsi in ssh al server bastion (o da console) e dare i comandi:
```bash
sudo su -

apt update; apt install -y curl
 export SECURE_PASS=tuaPasswordSicura
bash <(curl -s https://raw.githubusercontent.com/ESAOTE-EBIT/Bastion/refs/heads/main/02_semaphore_ui.sh)
```

#### Configurazione SemaphoreUI
1. Collegarsi all'interfaccia web di semaphore: http://bastion:3000/
2. Login con utente (ebit) e password usata nei passi precedenti.
3. Importare il json che si trova in questo repository (Ripristina progetto nel menù)
4. Modificare il nome del progetto da: Cruscotto -> Impostazioni
5. Modificare il valore della variabile secret con la password da usare nelle VM: Gruppi di variabili -> ebit -> Modifica -> Secrets ->  ubuntu_template_vm_password
6. Modificare il puntamento al repository GitHub: Repository
7. Modificare la chiave ssh per accesso a Github (usare quella generata nella creazione del server): Negozio di chiavi -> ebit_key (inserire la chiave ssh privata)
8. Clonare/creare un repository Github che conterrà i dati variabili della nostra installazione (ed: Laboratorio1)
9. Su Github inserire la chiave ssh pubblica (generata durante creazione vm bastion) tra le Deploy keys del repository relativo all'installazione
10. Procedere al lancio dei Playbook ansible.



