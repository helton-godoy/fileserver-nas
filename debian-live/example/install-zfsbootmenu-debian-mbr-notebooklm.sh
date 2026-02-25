#!/bin/bash
#
# Instalador Debian Trixie (Root on ZFS) - Estilo Void Linux com ZFSBootMenu
# Adaptado de: https://docs.zfsbootmenu.org/en/latest/guides/void-linux/uefi.html
#
# REQUISITOS:
# 1. Ambiente Live com 'zfsutils-linux', 'debootstrap', 'sgdisk', 'curl' e 'dosfstools'.
# 2. Boot em modo UEFI.
#

set -e

# --- CONFIGURAÇÃO ---
DISK="/dev/disk/by-id/SEU_ID_DE_DISCO_AQUI"  # Ex: /dev/disk/by-id/nvme-Samsung...
POOL_NAME="zroot"
HOSTNAME="debian-zbm"
USER_NAME="usuario"
# Nota: A senha de criptografia será solicitada interativamente pelo ZFS

# --- VERIFICAÇÕES ---
if [ "$(id -u)" -ne 0 ]; then
    echo "Erro: Execute como root."
    exit 1
fi

if [[ "$DISK" == *"SEU_ID"* ]]; then
    echo "Erro: Edite a variável DISK no script antes de executar."
    exit 1
fi

echo "!!! ATENÇÃO: O DISCO $DISK SERÁ COMPLETAMENTE APAGADO !!!"
read -p "Pressione Enter para continuar ou Ctrl+C para cancelar..."

# --- 1. LIMPEZA E PARTICIONAMENTO (Estilo Void: EFI + ZFS apenas) ---
echo "=> Limpando disco..."
sgdisk --zap-all "$DISK"

echo "=> Criando partições..."
# Partição 1: EFI (512MB)
sgdisk -n 1:1M:+512M -t 1:EF00 "$DISK"
# Partição 2: ZFS (Restante) - Tipo BF00 (Solaris Root)
sgdisk -n 2:0:0 -t 2:BF00 "$DISK"

# Detectar sufixo de partição (p1/p2 para nvme, 1/2 para sata)
if [[ "$DISK" == *"nvme"* ]]; then
    P1="${DISK}p1"; P2="${DISK}p2"
else
    P1="${DISK}1"; P2="${DISK}2"
fi

# Formatar EFI
mkfs.vfat -F32 -n EFI "$P1"

# --- 2. CRIAÇÃO DO POOL E DATASETS ---
# Adaptação: O Void usa criptografia nativa por padrão nos guias ZBM.
echo "=> Criando ZPool criptografado (Você definirá a senha agora)..."
zpool create -f -o ashift=12 \
    -O compression=lz4 \
    -O acltype=posixacl \
    -O xattr=sa \
    -O dnodesize=auto \
    -O normalization=formD \
    -O mountpoint=none \
    -O canmount=off \
    -O devices=off \
    -O encryption=aes-256-gcm \
    -O keylocation=prompt \
    -O keyformat=passphrase \
    -R /mnt \
    "$POOL_NAME" "$P2"

echo "=> Criando estrutura de Datasets..."
# Container ROOT
zfs create -o mountpoint=none "$POOL_NAME/ROOT"

# Dataset do Sistema (Debian Trixie)
# O parâmetro commandline é o segredo do ZFSBootMenu para eliminar o GRUB
zfs create -o mountpoint=/ -o canmount=noauto \
    -o org.zfsbootmenu:commandline="ro quiet splash" \
    "$POOL_NAME/ROOT/debian"

# Datasets adicionais (Home e Root separado, comum em setups ZFS)
zfs create -o mountpoint=/home "$POOL_NAME/home"
zfs create -o mountpoint=/root "$POOL_NAME/home/root"

# Montar o sistema
zpool export "$POOL_NAME"
zpool import -R /mnt "$POOL_NAME"
zfs mount "$POOL_NAME/ROOT/debian"
zfs mount -a

# Preparar Boot (EFI)
mkdir -p /mnt/boot/efi
mount "$P1" /mnt/boot/efi

# --- 3. BOOTSTRAP (A diferença principal: debootstrap vs xbps-install) ---
echo "=> Instalando sistema base Debian Trixie..."
# Inclui pacotes essenciais para compilar ZFS depois
debootstrap --arch amd64 trixie /mnt http://deb.debian.org/debian/

# --- 4. CONFIGURAÇÃO DO SISTEMA (CHROOT) ---
echo "=> Preparando chroot..."
mount --rbind /dev /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys /mnt/sys

# Gerar hostid (Crucial para ZFS no Linux)
if [ -f /etc/hostid ]; then
    cp /etc/hostid /mnt/etc/hostid
else
    # Se não existir, gera um aleatório
    dd if=/dev/urandom of=/mnt/etc/hostid bs=4 count=1
fi

# Copiar cache do pool
mkdir -p /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/

# Script executado DENTRO do novo sistema
cat <<EOF > /mnt/root/setup_internal.sh
#!/bin/bash
set -e

# Configurar Hostname
echo "$HOSTNAME" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1 localhost
127.0.1.1 $HOSTNAME
::1       localhost ip6-localhost ip6-loopback
HOSTS

# Configurar Repositórios (Necessário contrib/non-free para ZFS)
cat <<APT > /etc/apt/sources.list
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb http://deb.debian.org/debian-security trixie-security main contrib non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
APT

apt-get update

# Instalar Kernel, ZFS e Ferramentas
# No Void isso seria 'xbps-install -S zfs', no Debian é mais complexo devido ao DKMS
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    linux-image-amd64 \
    linux-headers-amd64 \
    zfs-dkms \
    zfsutils-linux \
    zfs-initramfs \
    curl \
    efibootmgr \
    dosfstools \
    locales \
    network-manager \
    openssh-server

# Configurar Locale
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# Configurar initramfs para carregar ZFS
# Isso garante que o Debian consiga montar o root após o ZBM passar o controle
update-initramfs -u -k all

# --- 5. INSTALAÇÃO DO ZFSBOOTMENU (Standalone) ---
# Em vez de compilar localmente (Void style 'generate-zbm'), baixamos o binário.
# Isso evita dependências do dracut no sistema host.

mkdir -p /boot/efi/EFI/ZBM
echo "=> Baixando ZFSBootMenu EFI..."
curl -L -o /boot/efi/EFI/ZBM/zfsbootmenu.efi https://get.zfsbootmenu.org/efi

# Adicionar entrada na BIOS/UEFI
# Remove entradas antigas para evitar duplicatas
efibootmgr -B -L "ZFSBootMenu" || true
efibootmgr -c -d "$DISK" \
    -p 1 \
    -L "ZFSBootMenu" \
    -l "\\EFI\\ZBM\\zfsbootmenu.efi"

# Configurar Usuário
useradd -m -s /bin/bash "$USER_NAME"
echo "Defina a senha para o usuário $USER_NAME:"
passwd "$USER_NAME"
echo "Defina a senha para o ROOT:"
passwd root

EOF

# Executar configuração interna
chmod +x /mnt/root/setup_internal.sh
chroot /mnt /root/setup_internal.sh
rm /mnt/root/setup_internal.sh

# --- 6. FINALIZAÇÃO ---
echo "=> Desmontando e exportando..."
umount -R /mnt/boot/efi
umount -R /mnt/dev
umount -R /mnt/proc
umount -R /mnt/sys
zfs umount -a
zpool export "$POOL_NAME"

echo "==========================================================="
echo "Instalação concluída!"
echo "O sistema agora usa ZFSBootMenu na partição EFI."
echo "Reinicie e selecione 'ZFSBootMenu' na ordem de boot."
echo "==========================================================="
