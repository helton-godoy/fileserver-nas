#!/bin/bash
set -e

# ========================================================================
# Script de Instalação do ZFSBootMenu no Debian Trixie (UEFI)
# Baseado em: https://docs.zfsbootmenu.org/en/v3.1.x/guides/debian/uefi.html
# ========================================================================

clear

echo "
==========================================
ZFSBootMenu - Instalação Debian Trixie
==========================================

AVISO: Este script irá APAGAR TODOS OS DADOS do disco selecionado!
Certifique-se de ter backups antes de continuar.
"

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then
    echo "
	ERRO: Este script precisa ser executado como root"
    exit 1
fi

# Verificar suporte EFI
echo "Verificando suporte EFI..."
if ! dmesg | grep -i efivars > /dev/null; then
    echo "
	ERRO: Sistema não possui suporte EFI/UEFI"
    exit 1
fi
echo "
✓ Suporte EFI detectado"


# 1. Instalar ZFS no ambiente live (se ainda não estiver instalado)
apt-get update -qq
apt-get install -qqy zfsutils-linux zfs-dkms  mokutil openssl

# 2. Gerar chave para assinar módulos
openssl req -new -x509 -newkey rsa:2048 -keyout MOK.priv -outform DER -out MOK.der -nodes -days 36500 -subj "/CN=ZFS Module Signing Key/"

# 3. Registrar a chave no MOK (Machine Owner Key)
mokutil --import MOK.der

# 4. Assinar o módulo ZFS
/usr/src/linux-headers-$(uname -r)/scripts/sign-file sha256 ./MOK.priv ./MOK.der $(modinfo -n zfs)

# 5. Carregar o módulo ZFS no kernel
modprobe zfs

# 3. Verificar se o módulo foi carregado
lsmod | grep zfs

echo "
✓ Dependências instaladas"


# ========================================================================
# 1. DEFINIR VARIÁVEIS DE DISCO
# ========================================================================

echo "
Discos disponíveis:
"
lsblk -d -o NAME,SIZE,TYPE | grep disk

read -p "Digite o dispositivo do disco (ex: sda ou nvme0n1): " DISK_NAME

if [[ $DISK_NAME == nvme* ]] || [[ $DISK_NAME == mmcblk* ]]; then
    export DISK="/dev/${DISK_NAME}"
    export BOOT_PART="p1"
    export POOL_PART="p2"
    export BOOT_DEVICE="${DISK}${BOOT_PART}"
    export POOL_DEVICE="${DISK}${POOL_PART}"
else
    export DISK="/dev/${DISK_NAME}"
    export BOOT_PART="1"
    export POOL_PART="2"
    export BOOT_DEVICE="${DISK}${BOOT_PART}"
    export POOL_DEVICE="${DISK}${POOL_PART}"
fi

echo "
Configuração do disco:
  Disco: $DISK
  Partição EFI: $BOOT_DEVICE
  Partição ZFS: $POOL_DEVICE
"

read -p "Continuar com esta configuração? (sim/não): " CONFIRM
if [ "$CONFIRM" != "sim" ]; then
    echo "Instalação cancelada."
    exit 0
fi

# Perguntar sobre criptografia
read -p "Deseja usar criptografia ZFS? (sim/não): " USE_ENCRYPTION

# ========================================================================
# 2. PARTICIONAR O DISCO
# ========================================================================

echo "
Particionando o disco $DISK..."

# Limpar o disco
sgdisk --zap-all "$DISK"

# Criar partições
sgdisk -n "${BOOT_PART}:1m:+512m" -t "${BOOT_PART}:ef00" "$DISK"
sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" "$DISK"

# Recarregar tabela de partições
partprobe "$DISK"
sleep 2

echo "
✓ Particionamento concluído"

# ========================================================================
# 3. FORMATAR PARTIÇÃO EFI
# ========================================================================

echo "
Formatando partição EFI..."
mkfs.vfat -F32 "$BOOT_DEVICE"
echo "
✓ Partição EFI formatada"

# ========================================================================
# 4. CRIAR POOL ZFS
# ========================================================================

echo "
Criando pool ZFS..."

# Gerar hostid se não existir
if [ ! -f /etc/hostid ]; then
    zgenhostid -f
fi

# Criar pool com ou sem criptografia
if [ "$USE_ENCRYPTION" = "sim" ]; then
    echo "Configure a senha de criptografia para o pool ZFS:"
    echo "IMPORTANTE: Você precisará digitar esta senha a cada boot!
    "
    
    zpool create -f -o ashift=12 \\
        -O compression=lz4 \\
        -O acltype=posixacl \\
        -O xattr=sa \\
        -O relatime=on \\
        -O normalization=formD \\
        -O encryption=aes-256-gcm \\
        -O keylocation=prompt \\
        -O keyformat=passphrase \\
        -o compatibility=openzfs-2.2-linux \\
        -o autotrim=on \\
        -m none zroot "$POOL_DEVICE"
else
    zpool create -f -o ashift=12 \\
        -O compression=lz4 \\
        -O acltype=posixacl \\
        -O xattr=sa \\
        -O relatime=on \\
        -O normalization=formD \\
        -o compatibility=openzfs-2.2-linux \\
        -o autotrim=on \\
        -m none zroot "$POOL_DEVICE"
fi

echo "
✓ Pool ZFS criado"

# ========================================================================
# 5. CRIAR DATASETS ZFS
# ========================================================================

echo "
Criando datasets ZFS..."

zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/debian
zfs create -o mountpoint=/home zroot/home

# Configurar dataset de boot
zpool set bootfs=zroot/ROOT/debian zroot

# Montar datasets
zfs mount zroot/ROOT/debian
zfs mount zroot/home

echo "
✓ Datasets criados e montados"

# ========================================================================
# 6. MONTAR PARTIÇÃO EFI
# ========================================================================

echo "
Montando partição EFI..."
mkdir -p /mnt/boot/efi
mount "$BOOT_DEVICE" /mnt/boot/efi
echo "
✓ Partição EFI montada"

# ========================================================================
# 7. INSTALAR DEBIAN BASE
# ========================================================================

echo "
Instalando sistema base Debian Trixie...
Isso pode levar alguns minutos..."

debootstrap trixie /mnt

echo "
✓ Sistema base instalado"

# ========================================================================
# 8. COPIAR ARQUIVOS NECESSÁRIOS
# ========================================================================

echo "
Copiando arquivos de configuração..."

cp /etc/hostid /mnt/etc/
cp /etc/resolv.conf /mnt/etc/

# Copiar chave de criptografia se foi usada
if [ "$USE_ENCRYPTION" = "sim" ]; then
    mkdir -p /mnt/etc/zfs
    # Nota: chave será configurada dentro do chroot
fi

echo "
✓ Arquivos copiados"

# ========================================================================
# 9. MONTAR SISTEMAS DE ARQUIVOS VIRTUAIS
# ========================================================================

echo "
Montando sistemas de arquivos virtuais..."

mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys
mount -B /dev /mnt/dev
mount -t devpts pts /mnt/dev/pts

echo "
✓ Sistemas de arquivos montados"

# ========================================================================
# 10. CRIAR SCRIPT DE CONFIGURAÇÃO CHROOT
# ========================================================================

cat > /mnt/root/configure-system.sh << '\''CHROOT_SCRIPT'\''
#!/bin/bash
set -e

echo "
==========================================
Configurando sistema dentro do chroot
==========================================
"

# Configurar apt sources
cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian trixie main contrib non-free non-free-firmware

deb http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware

deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
EOF

# Atualizar repositórios
apt update

# Configurar locale
apt install -y locales
echo "pt_BR.UTF-8 UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
update-locale LANG=pt_BR.UTF-8

# Configurar timezone
ln -sf /usr/share/zoneinfo/America/Cuiaba /etc/localtime

# Instalar kernel e ZFS
echo "
Instalando kernel e ZFS..."
apt install -y linux-headers-amd64 linux-image-amd64 zfs-initramfs dosfstools

# Configurar DKMS para ZFS
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf

# Habilitar serviços ZFS
systemctl enable zfs.target
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs-import.target

# Configurar hostname
read -p "Digite o hostname do sistema: " HOSTNAME
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1       localhost
127.0.1.1       $HOSTNAME

::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# Configurar root password
echo "
Configure a senha do root:"
passwd

# Instalar pacotes essenciais
echo "
Instalando pacotes essenciais..."
apt install -y curl wget vim nano sudo ssh network-manager

# Configurar fstab para partição EFI
BOOT_UUID=$(blkid -s UUID -o value $(findmnt -n -o SOURCE /boot/efi))
echo "UUID=$BOOT_UUID /boot/efi vfat defaults 0 0" >> /etc/fstab

# Instalar ZFSBootMenu
echo "
Instalando ZFSBootMenu..."
mkdir -p /boot/efi/EFI/ZBM
curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI

# Criar entrada de boot UEFI
apt install -y efibootmgr

BOOT_DISK=$(echo "$DISK" | sed '\''s/[0-9]*$//'\'' | sed '\''s/p$//'\'')
BOOT_PART_NUM=$(echo "$BOOT_DEVICE" | grep -o "[0-9]*$")

efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART_NUM" \\
    -L "ZFSBootMenu" \\
    -l "\\EFI\\ZBM\\VMLINUZ.EFI"

# Criar também entrada de boot padrão
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/BOOT/BOOTX64.EFI

# Configurar ZFSBootMenu
mkdir -p /etc/zfsbootmenu/dracut.conf.d
cat > /etc/zfsbootmenu/dracut.conf.d/zfsbootmenu.conf << EOF
# ZFSBootMenu Configuration
hostonly=no
hostonly_cmdline=no
EOF

# Gerar cache do ZFS pool
zpool set cachefile=/etc/zfs/zpool.cache zroot

echo "
✓ Configuração do sistema concluída!

Pressione Enter para continuar..."
read

CHROOT_SCRIPT

chmod +x /mnt/root/configure-system.sh

# ========================================================================
# 11. ENTRAR NO CHROOT E EXECUTAR CONFIGURAÇÃO
# ========================================================================

echo "
Entrando no ambiente chroot para configurar o sistema...
"

chroot /mnt /root/configure-system.sh

# ========================================================================
# 12. FINALIZAÇÃO
# ========================================================================

echo "
==========================================
Limpeza e finalização
=========================================="

# Desmontar sistemas de arquivos
umount /mnt/dev/pts
umount /mnt/dev
umount /mnt/sys
umount /mnt/proc
umount /mnt/boot/efi

# Exportar pool
zfs unmount -a
zpool export zroot

echo "
==========================================
✓ INSTALAÇÃO CONCLUÍDA!
==========================================

O sistema está pronto para ser inicializado.
Remova a mídia de instalação e reinicie o computador.

No boot, o ZFSBootMenu aparecerá e você poderá:
  - Selecionar o kernel a ser inicializado
  - Gerenciar snapshots ZFS
  - Acessar um shell de emergência
"
if [ "$USE_ENCRYPTION" = "sim" ]; then
    echo "LEMBRE-SE: Você precisará digitar a senha de criptografia"
    echo "do pool ZFS a cada boot!
	"
    
fi
echo "Deseja reiniciar agora? (sim/não)"
read -p "> " REBOOT_NOW

if [ "$REBOOT_NOW" = "sim" ]; then
    reboot
fi


# Salvar o script
# '/tmp/install-zfsbootmenu-debian.sh'
