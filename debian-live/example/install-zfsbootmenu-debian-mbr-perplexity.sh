#!/bin/bash
set -e

# ========================================================================
# Script de Instalação do ZFSBootMenu no Debian Trixie (SYSLINUX MBR)
# Baseado em: https://docs.zfsbootmenu.org/en/v3.1.x/guides/void-linux/syslinux-mbr.html
# Adaptado para Debian Trixie
# ========================================================================

echo "=========================================="
echo "ZFSBootMenu - Debian Trixie (MBR/BIOS)"
echo "=========================================="
echo ""
echo "AVISO: Este script irá APAGAR TODOS OS DADOS do disco selecionado!"
echo "Este modo usa BIOS/MBR (não UEFI)."
echo ""

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then
    echo "ERRO: Este script precisa ser executado como root"
    exit 1
fi

# Verificar que NÃO está em modo UEFI
if [ -d /sys/firmware/efi ]; then
    echo "AVISO: Sistema detectado em modo UEFI!"
    echo "Este script é para instalação MBR/BIOS."
    echo "Use o script UEFI se seu sistema usa UEFI."
    read -p "Deseja continuar mesmo assim? (sim/não): " FORCE_BIOS
    if [ "$FORCE_BIOS" != "sim" ]; then
        exit 1
    fi
fi

# ========================================================================
# 1. CONFIGURAR AMBIENTE LIVE
# ========================================================================

echo ""
echo "Configurando ambiente live..."

# Source /etc/os-release e exportar ID
source /etc/os-release
export ID="debian"

echo "✓ ID do sistema: $ID"

# Gerar /etc/hostid
zgenhostid -f 0x00bab10c
echo "✓ hostid gerado"

# ========================================================================
# 2. DEFINIR VARIÁVEIS DE DISCO
# ========================================================================

echo ""
echo "Discos disponíveis:"
lsblk -d -o NAME,SIZE,TYPE | grep disk
echo ""

read -p "Digite o dispositivo do disco (ex: sda ou nvme0n1): " DISK_NAME

# Determinar se é NVMe ou disco regular
if [[ $DISK_NAME == nvme* ]]; then
    export BOOT_DISK="/dev/${DISK_NAME}"
    export BOOT_PART="p1"
    export BOOT_DEVICE="${BOOT_DISK}${BOOT_PART}"
    export POOL_DISK="/dev/${DISK_NAME}"
    export POOL_PART="p2"
    export POOL_DEVICE="${POOL_DISK}${POOL_PART}"
else
    export BOOT_DISK="/dev/${DISK_NAME}"
    export BOOT_PART="1"
    export BOOT_DEVICE="${BOOT_DISK}${BOOT_PART}"
    export POOL_DISK="/dev/${DISK_NAME}"
    export POOL_PART="2"
    export POOL_DEVICE="${POOL_DISK}${POOL_PART}"
fi

echo ""
echo "Configuração do disco:"
echo "  Disco de boot: $BOOT_DISK"
echo "  Partição de boot: $BOOT_DEVICE (512MB, ext4)"
echo "  Disco do pool: $POOL_DISK"
echo "  Partição do pool: $POOL_DEVICE (restante)"
echo ""

read -p "Continuar com esta configuração? (sim/não): " CONFIRM
if [ "$CONFIRM" != "sim" ]; then
    echo "Instalação cancelada."
    exit 0
fi

# Perguntar sobre criptografia
read -p "Deseja usar criptografia ZFS? (sim/não): " USE_ENCRYPTION

# ========================================================================
# 3. PREPARAÇÃO DO DISCO (MBR)
# ========================================================================

echo ""
echo "Particionando o disco $POOL_DISK com tabela MBR..."

# Criar tabela de partições MBR
cat <<EOF | sfdisk "${POOL_DISK}"
label: dos
start=1MiB, size=512MiB, type=83, bootable
start=513MiB, size=+, type=83
EOF

# Recarregar tabela de partições
partprobe "$POOL_DISK"
sleep 2

echo "✓ Particionamento MBR concluído"

# ========================================================================
# 4. CRIAR POOL ZFS
# ========================================================================

echo ""
echo "Criando pool ZFS..."

if [ "$USE_ENCRYPTION" = "sim" ]; then
    # Criar arquivo de chave temporário
    echo "Digite a passphrase para criptografia do pool:"
    echo "(Esta será solicitada a cada boot)"
    echo ""
    mkdir -p /etc/zfs
    read -s -p "Passphrase: " PASSPHRASE
    echo ""
    echo "$PASSPHRASE" > /etc/zfs/zroot.key
    chmod 000 /etc/zfs/zroot.key
    
    zpool create -f -o ashift=12 \\
        -O compression=lz4 \\
        -O acltype=posixacl \\
        -O xattr=sa \\
        -O relatime=on \\
        -O encryption=aes-256-gcm \\
        -O keylocation=file:///etc/zfs/zroot.key \\
        -O keyformat=passphrase \\
        -o autotrim=on \\
        -o compatibility=openzfs-2.2-linux \\
        -m none zroot "$POOL_DEVICE"
else
    zpool create -f -o ashift=12 \\
        -O compression=lz4 \\
        -O acltype=posixacl \\
        -O xattr=sa \\
        -O relatime=on \\
        -o autotrim=on \\
        -o compatibility=openzfs-2.2-linux \\
        -m none zroot "$POOL_DEVICE"
fi

echo "✓ Pool ZFS criado"

# ========================================================================
# 5. CRIAR FILESYSTEMS INICIAIS
# ========================================================================

echo ""
echo "Criando filesystems ZFS..."

zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/${ID}
zfs create -o mountpoint=/home zroot/home
zpool set bootfs=zroot/ROOT/${ID} zroot

echo "✓ Filesystems criados"

# ========================================================================
# 6. EXPORTAR E RE-IMPORTAR COM MOUNTPOINT /mnt
# ========================================================================

echo ""
echo "Exportando e re-importando pool..."

zpool export zroot

if [ "$USE_ENCRYPTION" = "sim" ]; then
    zpool import -N -R /mnt zroot
    zfs load-key -L prompt zroot
else
    zpool import -N -R /mnt zroot
fi

zfs mount zroot/ROOT/${ID}
zfs mount zroot/home

echo "✓ Pool montado em /mnt"

# Verificar montagem
echo ""
echo "Verificando montagens:"
mount | grep mnt

# Atualizar symlinks de dispositivos
udevadm trigger

# ========================================================================
# 7. INSTALAR DEBIAN BASE
# ========================================================================

echo ""
echo "Instalando sistema base Debian Trixie..."
echo "Isso pode levar alguns minutos..."

debootstrap trixie /mnt http://deb.debian.org/debian

echo "✓ Sistema base instalado"

# ========================================================================
# 8. COPIAR ARQUIVOS NECESSÁRIOS
# ========================================================================

echo ""
echo "Copiando arquivos de configuração..."

cp /etc/hostid /mnt/etc/

if [ "$USE_ENCRYPTION" = "sim" ]; then
    mkdir -p /mnt/etc/zfs
    cp /etc/zfs/zroot.key /mnt/etc/zfs/
    chmod 000 /mnt/etc/zfs/zroot.key
fi

echo "✓ Arquivos copiados"

# ========================================================================
# 9. CRIAR SCRIPT DE CONFIGURAÇÃO CHROOT
# ========================================================================

cat > /mnt/root/configure-system.sh << 'CHROOT_SCRIPT'
#!/bin/bash
set -e

echo "=========================================="
echo "Configurando sistema (dentro do chroot)"
echo "=========================================="

# Exportar variáveis de disco
source /tmp/disk-vars.sh

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

# Instalar kernel e ferramentas básicas
echo ""
echo "Instalando kernel Linux e dependências..."
apt install -y linux-headers-amd64 linux-image-amd64

# Configurar Dracut para suporte ZFS
echo ""
echo "Configurando Dracut..."
mkdir -p /etc/dracut.conf.d

if [ -f /etc/zfs/zroot.key ]; then
    # Com criptografia
    cat > /etc/dracut.conf.d/zol.conf << EOF
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs "
install_items+=" /etc/zfs/zroot.key "
EOF
else
    # Sem criptografia
    cat > /etc/dracut.conf.d/zol.conf << EOF
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs "
EOF
fi

# Instalar ZFS
echo ""
echo "Instalando ZFS..."
apt install -y zfs-dkms zfsutils-linux dracut

# Habilitar serviços ZFS
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs.target

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

# Configurar senha do root
echo ""
echo "Configure a senha do root:"
passwd

# Instalar pacotes essenciais
echo ""
echo "Instalando pacotes essenciais..."
apt install -y vim nano curl wget sudo ssh network-manager

# ========================================================================
# INSTALAR E CONFIGURAR SYSLINUX
# ========================================================================

echo ""
echo "Instalando e configurando Syslinux..."

# Criar filesystem ext4 para boot
echo "Criando filesystem ext4 na partição de boot..."
mkfs.ext4 -O '^64bit' "$BOOT_DEVICE"

# Criar entrada no fstab e montar
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEVICE")
cat << EOF >> /etc/fstab
UUID=$BOOT_UUID /boot/syslinux ext4 defaults 0 0
EOF

mkdir -p /boot/syslinux
mount /boot/syslinux

# Instalar pacote syslinux
apt install -y syslinux extlinux mbr

# Copiar módulos syslinux
cp /usr/lib/syslinux/modules/bios/*.c32 /boot/syslinux/

# Instalar extlinux
extlinux --install /boot/syslinux

# Instalar MBR do syslinux
dd bs=440 count=1 conv=notrunc if=/usr/lib/syslinux/mbr/mbr.bin of="$BOOT_DISK"

echo "✓ Syslinux instalado"

# ========================================================================
# INSTALAR E CONFIGURAR ZFSBOOTMENU
# ========================================================================

echo ""
echo "Instalando ZFSBootMenu..."

# Definir propriedades ZFSBootMenu nos datasets
zfs set org.zfsbootmenu:commandline="quiet" zroot/ROOT

# Criar configuração do ZFSBootMenu
mkdir -p /etc/zfsbootmenu
cat > /etc/zfsbootmenu/config.yaml << EOF
Global:
  ManageImages: true
  BootMountPoint: /boot/syslinux
Components:
  Enabled: true
  Versions: false
  ImageDir: /boot/syslinux/zfsbootmenu
EOF

# Configurar syslinux.cfg
mkdir -p /boot/syslinux
cat > /boot/syslinux/syslinux.cfg << EOF
UI menu.c32
PROMPT 0
MENU TITLE ZFSBootMenu
TIMEOUT 50
DEFAULT zfsbootmenu

LABEL zfsbootmenu
MENU LABEL ZFSBootMenu
KERNEL /zfsbootmenu/vmlinuz-bootmenu
INITRD /zfsbootmenu/initramfs-bootmenu.img
APPEND zfsbootmenu quiet

LABEL zfsbootmenu-backup
MENU LABEL ZFSBootMenu (Backup)
KERNEL /zfsbootmenu/vmlinuz-bootmenu-backup
INITRD /zfsbootmenu/initramfs-bootmenu-backup.img
APPEND zfsbootmenu quiet
EOF

# Instalar generate-zbm (ferramenta para gerar imagens ZFSBootMenu)
echo ""
echo "Baixando e instalando generate-zbm..."

apt install -y curl cpanminus libconfig-inifiles-perl libsort-versions-perl libboolean-perl libyaml-pp-perl kpartx

# Baixar generate-zbm
mkdir -p /usr/local/bin
curl -o /usr/local/bin/generate-zbm -L https://get.zfsbootmenu.org/generate-zbm
chmod +x /usr/local/bin/generate-zbm

# Criar diretório para ZFSBootMenu
mkdir -p /boot/syslinux/zfsbootmenu

# Gerar cache do pool
zpool set cachefile=/etc/zfs/zpool.cache zroot

# Gerar imagens iniciais do ZFSBootMenu
echo ""
echo "Gerando imagens do ZFSBootMenu..."
echo "Isso pode levar alguns minutos..."

/usr/local/bin/generate-zbm

# Verificar se imagens foram criadas
if [ ! -f /boot/syslinux/zfsbootmenu/vmlinuz-bootmenu ]; then
    echo "AVISO: Imagens do ZFSBootMenu não foram geradas automaticamente."
    echo "Você precisará gerar manualmente após o boot executando: generate-zbm"
fi

echo "✓ ZFSBootMenu instalado e configurado"

echo ""
echo "✓ Configuração do sistema concluída!"
echo ""
echo "Pressione Enter para continuar..."
read

CHROOT_SCRIPT

chmod +x /mnt/root/configure-system.sh

# Salvar variáveis de disco para uso no chroot
cat > /mnt/tmp/disk-vars.sh << EOF
export BOOT_DISK="$BOOT_DISK"
export BOOT_PART="$BOOT_PART"
export BOOT_DEVICE="$BOOT_DEVICE"
export POOL_DISK="$POOL_DISK"
export POOL_PART="$POOL_PART"
export POOL_DEVICE="$POOL_DEVICE"
export ID="$ID"
EOF

# ========================================================================
# 10. MONTAR SISTEMAS DE ARQUIVOS E ENTRAR NO CHROOT
# ========================================================================

echo ""
echo "Montando sistemas de arquivos virtuais..."

mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys
mount -B /dev /mnt/dev
mount -t devpts pts /mnt/dev/pts

echo "✓ Sistemas de arquivos montados"

# ========================================================================
# 11. ENTRAR NO CHROOT E EXECUTAR CONFIGURAÇÃO
# ========================================================================

echo ""
echo "Entrando no ambiente chroot para configurar o sistema..."
echo ""

chroot /mnt /root/configure-system.sh

# ========================================================================
# 12. PREPARAR PARA PRIMEIRO BOOT
# ========================================================================

echo ""
echo "=========================================="
echo "Preparando para primeiro boot"
echo "=========================================="

# Sair do chroot (já saímos)
# Desmontar tudo
echo "Desmontando sistemas de arquivos..."

umount -l /mnt/dev/pts 2>/dev/null || true
umount -l /mnt/dev 2>/dev/null || true
umount -l /mnt/sys 2>/dev/null || true
umount -l /mnt/proc 2>/dev/null || true
umount -l /mnt/boot/syslinux 2>/dev/null || true

# Desmontar filesystems ZFS
zfs unmount -a

# Exportar pool
zpool export zroot

echo ""
echo "=========================================="
echo "✓ INSTALAÇÃO CONCLUÍDA!"
echo "=========================================="
echo ""
echo "O sistema está pronto para boot via BIOS/MBR."
echo "Remova a mídia de instalação e reinicie o computador."
echo ""
echo "No boot, o ZFSBootMenu aparecerá e você poderá:"
echo "  - Selecionar o ambiente de boot (boot environment)"
echo "  - Gerenciar snapshots ZFS"
echo "  - Acessar um shell de emergência"
echo ""

if [ "$USE_ENCRYPTION" = "sim" ]; then
    echo "IMPORTANTE: Como você configurou criptografia,"
    echo "será necessário digitar a passphrase a cada boot."
    echo ""
fi

echo "Deseja reiniciar agora? (sim/não)"
read -p "> " REBOOT_NOW

if [ "$REBOOT_NOW" = "sim" ]; then
    reboot
fi
'''

# Salvar o script
with open('/tmp/install-zfsbootmenu-debian-mbr.sh', 'w', encoding='utf-8') as f:
    f.write(script_content)

print("Script MBR criado com sucesso!")
print("\nInformações sobre o script:")
print(f"- Total de linhas: {len(script_content.splitlines())}")
print(f"- Tamanho: {len(script_content)} bytes")
print("\nDiferenças principais do script UEFI:")
print("- Usa tabela de partição MBR (DOS) ao invés de GPT")
print("- Usa Syslinux/Extlinux ao invés de bootloader EFI")
print("- Boot partition é ext4 ao invés de FAT32")
print("- Instala MBR no disco para boot via BIOS")