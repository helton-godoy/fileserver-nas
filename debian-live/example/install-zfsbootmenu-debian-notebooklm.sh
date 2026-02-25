#!/bin/bash
# 
# Automação de Instalação Debian Trixie com ZFSBootMenu (Root on ZFS)
# Baseado na documentação oficial do ZFSBootMenu e OpenZFS.
#
# REQUISITOS: Executar em um ambiente Live com suporte a ZFS e debootstrap instalado.
#

set -e

# ==========================================
# 1. CONFIGURAÇÃO (EDITE AQUI)
# ==========================================
DISK="/dev/vda"            # O disco alvo (CUIDADO! SERÁ APAGADO)
POOL_NAME="zroot"          # Nome do Pool ZFS
HOSTNAME="notebooklm-uefi" # Nome da máquina
USER_NAME="usuario"        # Nome do usuário comum
ENC_PASS="usuario"         # Senha para criptografia (Em produção, use prompt)

# Detectar partições (ajuste automático para NVMe vs SATA/Virtual)
if [[ "${DISK}" == *"nvme"* ]]; then
    PART_EFI="${DISK}p1"
    PART_ZFS="${DISK}p2"
else
    PART_EFI="${DISK}1"
    PART_ZFS="${DISK}2"
fi

# ==========================================
# 2. VERIFICAÇÕES INICIAIS
# ==========================================
if [ "$(id -u)" -ne 0 ]; then
    echo "Erro: Execute como root."
    exit 1
fi

echo "!!! ATENÇÃO !!!"
echo "O disco $DISK será COMPLETAMENTE FORMATADO."
echo "Você tem 5 segundos para cancelar (Ctrl+C)..."
sleep 5

# Instalar dependências necessárias no ambiente Live (se faltar)
command -v debootstrap >/dev/null 2>&1 || apt-get update && apt-get install -y debootstrap gdisk curl

# ==========================================
# 3. PARTICIONAMENTO
# ==========================================
echo "=> Limpando e particionando o disco..."
sgdisk --zap-all "$DISK"
# Partição 1: EFI (1GB) - Hex code EF00
sgdisk -n 1:1M:+1G -t 1:EF00 "$DISK"
# Partição 2: ZFS (Restante) - Hex code BF00 (Solaris Root)
sgdisk -n 2:0:0    -t 2:BF00 "$DISK"

# Formatar EFI
mkfs.vfat -F32 "$PART_EFI"

# ==========================================
# 4. CRIAÇÃO DO ZPOOL E DATASETS
# ==========================================
echo "=> Criando ZPool com criptografia nativa..."

# Opções otimizadas para SSD/NVMe e compatibilidade com ZBM
# ashift=12 (setores 4k), acltype=posixacl (necessário para Linux)
echo -n "$ENC_PASS" | zpool create -f -o ashift=12 \
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
    "$POOL_NAME" "$PART_ZFS"

echo "=> Criando hierarquia de Datasets..."
# Container ROOT (não montável)
zfs create -o canmount=off -o mountpoint=none "$POOL_NAME/ROOT"

# Dataset do Sistema Operacional
zfs create -o canmount=noauto -o mountpoint=/ "$POOL_NAME/ROOT/debian"

# Montar raiz manualmente para instalação
zfs mount "$POOL_NAME/ROOT/debian"

# Datasets separados para persistência e gestão
zfs create -o mountpoint=/home "$POOL_NAME/home"
zfs create -o mountpoint=/root "$POOL_NAME/home/root"
zfs create -o canmount=off -o mountpoint=/var "$POOL_NAME/var"
zfs create -o mountpoint=/var/log "$POOL_NAME/var/log"
zfs create -o mountpoint=/var/lib "$POOL_NAME/var/lib"

# Configuração EXCLUSIVA do ZFSBootMenu
# Define qual kernel usar e argumentos de boot direto no ZFS
zfs set org.zfsbootmenu:commandline="quiet splash ro" "$POOL_NAME/ROOT/debian"

# ==========================================
# 5. BOOTSTRAP (Debian Trixie)
# ==========================================
echo "=> Instalando sistema base (Trixie)..."
debootstrap --arch amd64 trixie /mnt http://deb.debian.org/debian/

# Preparar montagens para chroot
mkdir -p /mnt/boot/efi
mount "$PART_EFI" /mnt/boot/efi
mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys

# Gerar hostid (Crucial para ZFS importar o pool corretamente no boot)
# Se zgenhostid não existir no live, gera um aleatório
if command -v zgenhostid >/dev/null; then
    zgenhostid -f -o /mnt/etc/hostid
else
    dd if=/dev/urandom of=/mnt/etc/hostid bs=4 count=1
fi

# Copiar cache do pool (se existir)
mkdir -p /mnt/etc/zfs
if [ -f /etc/zfs/zpool.cache ]; then
    cp /etc/zfs/zpool.cache /mnt/etc/zfs/
fi

# ==========================================
# 6. CONFIGURAÇÃO DENTRO DO CHROOT
# ==========================================
echo "=> Configurando o sistema..."

cat <<EOF > /mnt/root/setup_internal.sh
#!/bin/bash
set -e

# Configurar Hostname
echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 localhost" > /etc/hosts
echo "127.0.1.1 $HOSTNAME" >> /etc/hosts

# Configurar APT (Adicionar contrib e non-free-firmware para ZFS)
cat <<APT > /etc/apt/sources.list
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free-firmware
APT

apt-get update

# Instalar Kernel, Headers e ZFS
# DEBIAN_FRONTEND=noninteractive evita prompts interativos
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    linux-image-amd64 \
    linux-headers-amd64 \
    zfs-dkms \
    zfsutils-linux \
    zfs-initramfs \
    dosfstools \
    efibootmgr \
    curl \
    locales \
    console-setup

# Configurar Locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# Criar usuário
useradd -m -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$ENC_PASS" | chpasswd
echo "root:$ENC_PASS" | chpasswd

# ==========================================
# 7. INSTALAÇÃO DO ZFSBOOTMENU (Standalone)
# ==========================================
echo "=> Instalando ZFSBootMenu..."

# Criar diretórios EFI
mkdir -p /boot/efi/EFI/ZBM

# Baixar a versão release mais recente do ZFSBootMenu (Standalone EFI)
# Nota: Esta URL baixa o binário pré-compilado, que é o método recomendado
# para evitar compilar dracut/initramfs complexos no host.
curl -L -o /boot/efi/EFI/ZBM/zfsbootmenu.efi https://get.zfsbootmenu.org/efi

# Configurar entrada de boot UEFI
# Remove entrada anterior se existir para evitar duplicidade
efibootmgr -B -L "ZFSBootMenu" || true
efibootmgr -c -d "$DISK" -p 1 -L "ZFSBootMenu" -l "\\EFI\\ZBM\\zfsbootmenu.efi"

# Configurar Initramfs do sistema para carregar ZFS
# Garante que o hostid está incluído
update-initramfs -u -k all

EOF

# Executar script interno
chmod +x /mnt/root/setup_internal.sh
chroot /mnt /root/setup_internal.sh
rm /mnt/root/setup_internal.sh

# ==========================================
# 8. FINALIZAÇÃO
# ==========================================
echo "=> Exportando pool e finalizando..."
# Desmontar sistemas de arquivos
umount -R /mnt/boot/efi || true
umount -R /mnt/dev || true
umount -R /mnt/proc || true
umount -R /mnt/sys || true

# Snapshot inicial (opcional, mas recomendado)
zfs snapshot "$POOL_NAME/ROOT/debian@install"

# Exportar pool
zpool export "$POOL_NAME"

echo "==========================================="
echo " Instalação Concluída!"
echo " Senha do usuário '$USER_NAME': $ENC_PASS"
echo " Reinicie o sistema e selecione ZFSBootMenu na BIOS/UEFI."
echo "==========================================="