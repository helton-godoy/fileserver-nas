#!/bin/bash
#
# Instalador Automatizado Debian Trixie (Híbrido UEFI/BIOS)
# Baseado na documentação oficial do Debian e OpenZFS para particionamento.
#
# REQUISITOS: debootstrap, dosfstools, gdisk, efibootmgr (para UEFI), grub-pc (para BIOS)
#

set -e

# ==========================================
# 1. CONFIGURAÇÃO (EDITE AQUI)
# ==========================================
DISK="/dev/vda"             # Disco alvo (CUIDADO! SERÁ FORMATADO)
HOSTNAME="debian-trixie"    # Nome da máquina
USER_NAME="usuario"         # Nome do usuário comum
USER_PASS="usuario"        # Senha do usuário
ROOT_PASS="root"      # Senha do root

# ==========================================
# 2. DETECÇÃO DO MODO DE BOOT
# ==========================================
if [ -d "/sys/firmware/efi" ]; then
    BOOT_MODE="UEFI"
    echo "=> Modo de Boot Detectado: UEFI"
else
    BOOT_MODE="BIOS"
    echo "=> Modo de Boot Detectado: BIOS (Legacy)"
fi

# Verificação de root
if [ "$(id -u)" -ne 0 ]; then
    echo "Erro: Execute como root."
    exit 1
fi

echo "!!! ATENÇÃO: O DISCO $DISK SERÁ APAGADO EM 5 SEGUNDOS !!!"
sleep 5

# Instalar dependências no ambiente Live se necessário
command -v debootstrap >/dev/null 2>&1 || apt-get update && apt-get install -y debootstrap gdisk dosfstools

# ==========================================
# 3. PARTICIONAMENTO ADAPTATIVO
# ==========================================
echo "=> Limpando disco..."
sgdisk --zap-all "$DISK"

if [ "$BOOT_MODE" == "UEFI" ]; then
    # -- LAYOUT UEFI --
    # Partição 1: EFI (512MB) - Hex EF00
    # Partição 2: Swap (4GB)  - Hex 8200
    # Partição 3: Root (Resto) - Hex 8300
    echo "=> Criando tabela de partição GPT para UEFI..."
    sgdisk -n 1:0:+512M -t 1:EF00 -c 1:"EFI System" "$DISK"
    sgdisk -n 2:0:+4G   -t 2:8200 -c 2:"Linux Swap" "$DISK"
    sgdisk -n 3:0:0     -t 3:8300 -c 3:"Linux Root" "$DISK"
    
    # Definir variáveis de partição (ajuste para NVMe vs SATA)
    if [[ "${DISK}" == *"nvme"* ]]; then
        P_EFI="${DISK}p1"; P_SWAP="${DISK}p2"; P_ROOT="${DISK}p3"
    else
        P_EFI="${DISK}1"; P_SWAP="${DISK}2"; P_ROOT="${DISK}3"
    fi

    echo "=> Formatando partições UEFI..."
    mkfs.vfat -F32 "$P_EFI"
    mkswap "$P_SWAP"
    mkfs.ext4 -F "$P_ROOT"

else
    # -- LAYOUT BIOS --
    # Partição 1: BIOS Boot (1MB) - Hex EF02 (Necessário para GPT em BIOS)
    # Partição 2: Swap (4GB)      - Hex 8200
    # Partição 3: Root (Resto)    - Hex 8300
    echo "=> Criando tabela de partição GPT para BIOS (Legacy)..."
    sgdisk -n 1:0:+1M   -t 1:EF02 -c 1:"BIOS Boot"  "$DISK"
    sgdisk -n 2:0:+4G   -t 2:8200 -c 2:"Linux Swap" "$DISK"
    sgdisk -n 3:0:0     -t 3:8300 -c 3:"Linux Root" "$DISK"

    if [[ "${DISK}" == *"nvme"* ]]; then
        P_SWAP="${DISK}p2"; P_ROOT="${DISK}p3"
    else
        P_SWAP="${DISK}2"; P_ROOT="${DISK}3"
    fi

    echo "=> Formatando partições BIOS..."
    # Não formatamos a partição 1 (BIOS Boot), o GRUB a usa diretamente
    mkswap "$P_SWAP"
    mkfs.ext4 -F "$P_ROOT"
fi

# ==========================================
# 4. MONTAGEM E BOOTSTRAP
# ==========================================
echo "=> Montando sistemas de arquivos..."
mount "$P_ROOT" /mnt
swapon "$P_SWAP"

if [ "$BOOT_MODE" == "UEFI" ]; then
    mkdir -p /mnt/boot/efi
    mount "$P_EFI" /mnt/boot/efi
fi

echo "=> Executando debootstrap (Trixie)..."
debootstrap --arch amd64 trixie /mnt http://deb.debian.org/debian/

# ==========================================
# 5. CONFIGURAÇÃO DO SISTEMA
# ==========================================
echo "=> Configurando fstab e binds..."
# Gerar fstab básico
if [ "$BOOT_MODE" == "UEFI" ]; then
    echo "UUID=$(blkid -s UUID -o value $P_EFI)  /boot/efi  vfat  umask=0077  0  1" >> /mnt/etc/fstab
fi
echo "UUID=$(blkid -s UUID -o value $P_ROOT) /          ext4  defaults    0  1" >> /mnt/etc/fstab
echo "UUID=$(blkid -s UUID -o value $P_SWAP) none       swap  sw          0  0" >> /mnt/etc/fstab

# Preparar Chroot
mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys

# Criar script de configuração interna
cat <<EOF > /mnt/root/setup_internal.sh
#!/bin/bash
set -e

# Configurar Hostname
echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 localhost" > /etc/hosts
echo "127.0.1.1 $HOSTNAME" >> /etc/hosts

# Configurar APT
cat <<APT > /etc/apt/sources.list
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb http://deb.debian.org/debian-security trixie-security main contrib non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
APT

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y linux-image-amd64 linux-headers-amd64 locales network-manager openssh-server

# Configurar Locale
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# Usuários
useradd -m -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "root:$ROOT_PASS" | chpasswd

# Instalação do GRUB Condicional
if [ "$BOOT_MODE" == "UEFI" ]; then
    echo "=> Instalando GRUB para UEFI..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y grub-efi-amd64 efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Debian --recheck
else
    echo "=> Instalando GRUB para BIOS..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y grub-pc
    grub-install --target=i386-pc --recheck "$DISK"
fi

update-grub
EOF

# Executar configuração no chroot
chmod +x /mnt/root/setup_internal.sh
chroot /mnt /root/setup_internal.sh
rm /mnt/root/setup_internal.sh

# ==========================================
# 6. FINALIZAÇÃO
# ==========================================
echo "=> Desmontando e finalizando..."
umount -R /mnt
swapoff "$P_SWAP"

echo "==========================================="
echo " Instalação do Debian Trixie Concluída!"
echo " Modo: $BOOT_MODE"
echo " Usuário: $USER_NAME"
echo " Reinicie a máquina."
echo "==========================================="
