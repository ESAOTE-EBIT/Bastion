#!/bin/bash

# Richiesta prima password
read -s -p "Inserisci la password: " password1
echo
# Richiesta seconda password
read -s -p "Reinserisci la password: " password2
echo

# Verifica
if [ "$password1" == "$password2" ]; then
    echo "Password confermata correttamente."
else
    echo "Le password non corrispondono. Riprova."
    exit 1
fi
echo "Ricordati di conservare questa password in un luogo sicuro"
SECURE_PASS=$password1;
#export OS_IMAGE="debian-12-generic-amd64.qcow3"
export OS_IMAGE="noble-server-cloudimg-amd64.img"  
#export OS_URL="https://cloud.debian.org/images/cloud/bookworm/latest/$OS_IMAGE"
export OS_URL="https://cloud-images.ubuntu.com/noble/current/$OS_IMAGE"

cd /tmp
wget "$OS_URL"
apt install -y libguestfs-tools
qm_id=9001         
virt-customize -a /tmp/$OS_IMAGE --install qemu-guest-agent
virt-customize -a /tmp/$OS_IMAGE --timezone Europe/Rome
virt-customize -a /tmp/$OS_IMAGE \
  --run-command 'systemctl enable ssh' \
  --run-command 'sed -i "s/^PasswordAuthentication no/PasswordAuthentication yes/" /etc/ssh/sshd_config' \
  --run-command 'sed -i "s/^PasswordAuthentication no/PasswordAuthentication yes/" /etc/ssh/sshd_config.d/60-cloudimg-settings.conf' \
  --run-command 'systemctl restart ssh'
qm create $qm_id --name bastion --memory 2048 --core 2
qm importdisk $qm_id /tmp/$OS_IMAGE local-lvm
qm set $qm_id --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-$qm_id-disk-0
qm set $qm_id --ide2 local-lvm:cloudinit
qm set $qm_id --boot c --bootdisk scsi0
qm set $qm_id --serial0 socket --vga serial0
qm set $qm_id --agent enabled=1
qm set $qm_id --ciuser ebit
qm set $qm_id --cipassword $SECURE_PASS
qm set $qm_id --net0 virtio,bridge=vmbr0 --ipconfig0 'ip=192.168.72.123/24,gw=192.168.72.254'
qm resize $qm_id scsi0 5G
qm start $qm_id
rm -f $OS_IMAGE
echo "Adesso è possibile collegarsi al server in ssh"
