#!/bin/bash
set -e

# ========================================================================
# Script de Instalação Universal do ZFSBootMenu no Debian Trixie
# Detecta automaticamente UEFI ou BIOS e realiza instalação adequada
# ========================================================================

# Cores para output
RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
BLUE='\\033[0;34m'
NC='\\033[0m' # No Color

# Função para mensagens coloridas
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERRO]${NC} $1"
}

# ========================================================================
# FUNÇÃO: DETECTAR MODO DE BOOT
# ========================================================================

detect_boot_mode() {
    print_info "Detectando modo de boot do sistema..."
    
    if [ -d /sys/firmware/efi ]; then
        BOOT_MODE="UEFI"
        print_success "Sistema detectado em modo UEFI"
    else
        BOOT_MODE="BIOS"
        print_success "Sistema detectado em modo BIOS/Legacy"
    fi
    
    export BOOT_MODE
}

# ========================================================================
# FUNÇÃO: CONFIGURAÇÃO INICIAL COMUM
# ========================================================================

initial_setup() {
    echo ""
    echo "=========================================="
    echo "ZFSBootMenu - Instalação Debian Trixie"
    echo "Modo: $BOOT_MODE"
    echo "=========================================="
    echo ""
    
    print_warning "Este script irá APAGAR TODOS OS DADOS do disco selecionado!"
    echo ""
    
    # Verificar se está rodando como root
    if [ "$EUID" -ne 0 ]; then
        print_error "Este script precisa ser executado como root"
        exit 1
    fi
    
    print_info "Configurando ambiente live..."
    
    # Source /etc/os-release e exportar ID
    source /etc/os-release
    export ID="debian"
    
    # Gerar /etc/hostid
    zgenhostid -f 0x00bab10c
    print_success "hostid gerado: $(cat /etc/hostid | xxd -p)"
}

# ========================================================================
# FUNÇÃO: SELEÇÃO E CONFIGURAÇÃO DO DISCO
# ========================================================================

configure_disk() {
    echo ""
    print_info "Discos disponíveis:"
    lsblk -d -o NAME,SIZE,TYPE,MODEL | grep disk
    echo ""
    
    read -p "Digite o dispositivo do disco (ex: sda ou nvme0n1): " DISK_NAME
    
    # Determinar se é NVMe ou disco regular
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
    
    echo ""
    echo "Configuração do disco:"
    echo "  Disco: $DISK"
    echo "  Partição de boot: $BOOT_DEVICE (512MB)"
    echo "  Partição ZFS: $POOL_DEVICE (restante)"
    echo ""
    
    read -p "Continuar com esta configuração? (sim/não): " CONFIRM
    if [ "$CONFIRM" != "sim" ]; then
        print_warning "Instalação cancelada pelo usuário."
        exit 0
    fi
    
    # Perguntar sobre criptografia
    read -p "Deseja usar criptografia ZFS? (sim/não): " USE_ENCRYPTION
    export USE_ENCRYPTION
}

# ========================================================================
# FUNÇÃO: PARTICIONAMENTO UEFI (GPT)
# ========================================================================

partition_disk_uefi() {
    print_info "Particionando disco para UEFI (GPT)..."
    
    # Limpar o disco
    sgdisk --zap-all "$DISK"
    
    # Criar partições GPT
    sgdisk -n "${BOOT_PART}:1m:+512m" -t "${BOOT_PART}:ef00" "$DISK"
    sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" "$DISK"
    
    # Recarregar tabela de partições
    partprobe "$DISK"
    sleep 2
    
    print_success "Particionamento GPT concluído"
}

# ========================================================================
# FUNÇÃO: PARTICIONAMENTO BIOS (MBR)
# ========================================================================

partition_disk_bios() {
    print_info "Particionando disco para BIOS (MBR)..."
    
    # Criar tabela de partições MBR
    cat <<EOF | sfdisk "${DISK}"
label: dos
start=1MiB, size=512MiB, type=83, bootable
start=513MiB, size=+, type=83
EOF
    
    # Recarregar tabela de partições
    partprobe "$DISK"
    sleep 2
    
    print_success "Particionamento MBR concluído"
}

# ========================================================================
# FUNÇÃO: CRIAR POOL ZFS
# ========================================================================

create_zfs_pool() {
    print_info "Criando pool ZFS..."
    
    if [ "$USE_ENCRYPTION" = "sim" ]; then
        echo ""
        print_warning "Configure a senha de criptografia para o pool ZFS:"
        echo "IMPORTANTE: Você precisará digitar esta senha a cada boot!"
        echo ""
        
        mkdir -p /etc/zfs
        read -s -p "Passphrase: " PASSPHRASE
        echo ""
        read -s -p "Confirme a passphrase: " PASSPHRASE2
        echo ""
        
        if [ "$PASSPHRASE" != "$PASSPHRASE2" ]; then
            print_error "As senhas não coincidem!"
            exit 1
        fi
        
        echo "$PASSPHRASE" > /etc/zfs/zroot.key
        chmod 000 /etc/zfs/zroot.key
        
        zpool create -f -o ashift=12 \\
            -O compression=lz4 \\
            -O acltype=posixacl \\
            -O xattr=sa \\
            -O relatime=on \\
            -O normalization=formD \\
            -O encryption=aes-256-gcm \\
            -O keylocation=file:///etc/zfs/zroot.key \\
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
    
    print_success "Pool ZFS criado"
}

# ========================================================================
# FUNÇÃO: CRIAR DATASETS ZFS
# ========================================================================

create_zfs_datasets() {
    print_info "Criando datasets ZFS..."
    
    zfs create -o mountpoint=none zroot/ROOT
    zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/${ID}
    zfs create -o mountpoint=/home zroot/home
    
    # Configurar dataset de boot
    zpool set bootfs=zroot/ROOT/${ID} zroot
    
    # Configurar propriedades ZFSBootMenu
    zfs set org.zfsbootmenu:commandline="quiet" zroot/ROOT
    
    print_success "Datasets criados"
}

# ========================================================================
# FUNÇÃO: MONTAR DATASETS
# ========================================================================

mount_datasets() {
    print_info "Exportando e re-importando pool..."
    
    zpool export zroot
    
    if [ "$USE_ENCRYPTION" = "sim" ]; then
        zpool import -N -R /mnt zroot
        zfs load-key -L prompt zroot
    else
        zpool import -N -R /mnt zroot
    fi
    
    zfs mount zroot/ROOT/${ID}
    zfs mount zroot/home
    
    print_success "Pool montado em /mnt"
    
    # Atualizar symlinks de dispositivos
    udevadm trigger
}

# ========================================================================
# FUNÇÃO: INSTALAR DEBIAN BASE
# ========================================================================

install_debian_base() {
    print_info "Instalando sistema base Debian Trixie..."
    echo "Isso pode levar alguns minutos..."
    
    debootstrap trixie /mnt http://deb.debian.org/debian
    
    print_success "Sistema base instalado"
    
    # Copiar arquivos necessários
    print_info "Copiando arquivos de configuração..."
    cp /etc/hostid /mnt/etc/
    cp /etc/resolv.conf /mnt/etc/
    
    if [ "$USE_ENCRYPTION" = "sim" ]; then
        mkdir -p /mnt/etc/zfs
        cp /etc/zfs/zroot.key /mnt/etc/zfs/
        chmod 000 /mnt/etc/zfs/zroot.key
    fi
    
    print_success "Arquivos copiados"
}

# ========================================================================
# FUNÇÃO: MONTAR SISTEMAS DE ARQUIVOS VIRTUAIS
# ========================================================================

mount_virtual_filesystems() {
    print_info "Montando sistemas de arquivos virtuais..."
    
    mount -t proc proc /mnt/proc
    mount -t sysfs sys /mnt/sys
    mount -B /dev /mnt/dev
    mount -t devpts pts /mnt/dev/pts
    
    print_success "Sistemas de arquivos montados"
}

# ========================================================================
# FUNÇÃO: CRIAR SCRIPT CHROOT COMUM
# ========================================================================

create_common_chroot_script() {
    cat > /mnt/root/configure-base.sh << 'BASE_SCRIPT'
#!/bin/bash
set -e

# Carregar variáveis
source /tmp/install-vars.sh

echo "=========================================="
echo "Configurando sistema base (chroot)"
echo "=========================================="

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
echo ""
echo "Instalando kernel, ZFS e dependências..."
apt install -y linux-headers-amd64 linux-image-amd64 zfs-dkms zfsutils-linux

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

# Configurar senha do root
echo ""
echo "Configure a senha do root:"
passwd

# Instalar pacotes essenciais
echo ""
echo "Instalando pacotes essenciais..."
apt install -y vim nano curl wget sudo ssh network-manager dosfstools

# Gerar cache do ZFS pool
zpool set cachefile=/etc/zfs/zpool.cache zroot

echo "✓ Configuração base concluída"

BASE_SCRIPT

    chmod +x /mnt/root/configure-base.sh
}

# ========================================================================
# FUNÇÃO: CONFIGURAÇÃO ESPECÍFICA UEFI
# ========================================================================

configure_uefi() {
    print_info "Configurando bootloader UEFI..."
    
    # Formatar partição EFI
    mkfs.vfat -F32 "$BOOT_DEVICE"
    
    # Montar partição EFI
    mkdir -p /mnt/boot/efi
    mount "$BOOT_DEVICE" /mnt/boot/efi
    
    # Criar script de configuração UEFI
    cat > /mnt/root/configure-uefi.sh << 'UEFI_SCRIPT'
#!/bin/bash
set -e

source /tmp/install-vars.sh

echo ""
echo "Configurando UEFI boot..."

# Adicionar entrada fstab para EFI
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEVICE")
echo "UUID=$BOOT_UUID /boot/efi vfat defaults 0 0" >> /etc/fstab

# Instalar ZFSBootMenu
echo "Instalando ZFSBootMenu..."
mkdir -p /boot/efi/EFI/ZBM

# Baixar ZFSBootMenu EFI
curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI

# Instalar efibootmgr
apt install -y efibootmgr

# Criar entrada de boot UEFI
BOOT_DISK_CLEAN=$(echo "$DISK" | sed 's/[0-9]*$//' | sed 's/p$//')
BOOT_PART_NUM=$(echo "$BOOT_DEVICE" | grep -o "[0-9]*$")

efibootmgr -c -d "$BOOT_DISK_CLEAN" -p "$BOOT_PART_NUM" \\
    -L "ZFSBootMenu" \\
    -l "\\EFI\\ZBM\\VMLINUZ.EFI"

# Criar entrada de boot padrão
mkdir -p /boot/efi/EFI/BOOT
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/BOOT/BOOTX64.EFI

echo "✓ Configuração UEFI concluída"

UEFI_SCRIPT

    chmod +x /mnt/root/configure-uefi.sh
}

# ========================================================================
# FUNÇÃO: CONFIGURAÇÃO ESPECÍFICA BIOS
# ========================================================================

configure_bios() {
    print_info "Configurando bootloader BIOS/Syslinux..."
    
    # Criar script de configuração BIOS
    cat > /mnt/root/configure-bios.sh << 'BIOS_SCRIPT'
#!/bin/bash
set -e

source /tmp/install-vars.sh

echo ""
echo "Configurando BIOS boot..."

# Instalar Dracut
apt install -y dracut

# Configurar Dracut para ZFS
mkdir -p /etc/dracut.conf.d

if [ -f /etc/zfs/zroot.key ]; then
    cat > /etc/dracut.conf.d/zol.conf << EOF
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs "
install_items+=" /etc/zfs/zroot.key "
EOF
else
    cat > /etc/dracut.conf.d/zol.conf << EOF
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs "
EOF
fi

# Criar filesystem ext4 para boot
echo "Criando filesystem ext4 na partição de boot..."
mkfs.ext4 -O '^64bit' "$BOOT_DEVICE"

# Configurar fstab e montar
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEVICE")
cat << EOF >> /etc/fstab
UUID=$BOOT_UUID /boot/syslinux ext4 defaults 0 0
EOF

mkdir -p /boot/syslinux
mount /boot/syslinux

# Instalar Syslinux
apt install -y syslinux extlinux mbr

# Copiar módulos syslinux
cp /usr/lib/syslinux/modules/bios/*.c32 /boot/syslinux/

# Instalar extlinux
extlinux --install /boot/syslinux

# Instalar MBR
dd bs=440 count=1 conv=notrunc if=/usr/lib/syslinux/mbr/mbr.bin of="$DISK"

# Configurar syslinux.cfg
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

# Instalar generate-zbm
echo "Instalando generate-zbm..."
apt install -y cpanminus libconfig-inifiles-perl libsort-versions-perl libboolean-perl libyaml-pp-perl kpartx

curl -o /usr/local/bin/generate-zbm -L https://get.zfsbootmenu.org/generate-zbm
chmod +x /usr/local/bin/generate-zbm

# Criar configuração ZFSBootMenu
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

# Criar diretório para imagens
mkdir -p /boot/syslinux/zfsbootmenu

# Gerar imagens ZFSBootMenu
echo "Gerando imagens ZFSBootMenu..."
/usr/local/bin/generate-zbm || echo "AVISO: Execute 'generate-zbm' manualmente após o boot"

echo "✓ Configuração BIOS concluída"

BIOS_SCRIPT

    chmod +x /mnt/root/configure-bios.sh
}

# ========================================================================
# FUNÇÃO: EXECUTAR CONFIGURAÇÃO NO CHROOT
# ========================================================================

run_chroot_configuration() {
    # Salvar variáveis para uso no chroot
    cat > /mnt/tmp/install-vars.sh << EOF
export BOOT_MODE="$BOOT_MODE"
export DISK="$DISK"
export BOOT_DEVICE="$BOOT_DEVICE"
export POOL_DEVICE="$POOL_DEVICE"
export USE_ENCRYPTION="$USE_ENCRYPTION"
export ID="$ID"
EOF
    
    print_info "Entrando no ambiente chroot..."
    
    # Executar configuração base
    chroot /mnt /root/configure-base.sh
    
    # Executar configuração específica do modo de boot
    if [ "$BOOT_MODE" = "UEFI" ]; then
        chroot /mnt /root/configure-uefi.sh
    else
        chroot /mnt /root/configure-bios.sh
    fi
}

# ========================================================================
# FUNÇÃO: FINALIZAÇÃO E LIMPEZA
# ========================================================================

finalize_installation() {
    print_info "Finalizando instalação..."
    
    # Desmontar sistemas de arquivos
    umount -l /mnt/dev/pts 2>/dev/null || true
    umount -l /mnt/dev 2>/dev/null || true
    umount -l /mnt/sys 2>/dev/null || true
    umount -l /mnt/proc 2>/dev/null || true
    
    if [ "$BOOT_MODE" = "UEFI" ]; then
        umount -l /mnt/boot/efi 2>/dev/null || true
    else
        umount -l /mnt/boot/syslinux 2>/dev/null || true
    fi
    
    # Desmontar e exportar pool ZFS
    zfs unmount -a
    zpool export zroot
    
    print_success "Limpeza concluída"
}

# ========================================================================
# FUNÇÃO: MENSAGEM FINAL
# ========================================================================

show_completion_message() {
    echo ""
    echo "=========================================="
    print_success "INSTALAÇÃO CONCLUÍDA!"
    echo "=========================================="
    echo ""
    echo "Modo de boot: $BOOT_MODE"
    echo "Pool ZFS: zroot"
    echo "Dataset raiz: zroot/ROOT/debian"
    echo ""
    
    if [ "$BOOT_MODE" = "UEFI" ]; then
        echo "Bootloader: ZFSBootMenu (EFI)"
        echo "Partição EFI: $BOOT_DEVICE"
    else
        echo "Bootloader: ZFSBootMenu (Syslinux/MBR)"
        echo "Partição boot: $BOOT_DEVICE (ext4)"
    fi
    
    echo ""
    echo "No próximo boot, o ZFSBootMenu permitirá:"
    echo "  • Selecionar o ambiente de boot"
    echo "  • Gerenciar snapshots ZFS"
    echo "  • Acessar shell de emergência"
    echo ""
    
    if [ "$USE_ENCRYPTION" = "sim" ]; then
        print_warning "CRIPTOGRAFIA ATIVA: Você precisará digitar a"
        echo "           passphrase do pool ZFS a cada boot!"
        echo ""
    fi
    
    read -p "Deseja reiniciar agora? (sim/não): " REBOOT_NOW
    
    if [ "$REBOOT_NOW" = "sim" ]; then
        print_info "Reiniciando sistema..."
        sleep 2
        reboot
    else
        print_info "Remova a mídia de instalação e reinicie manualmente."
    fi
}

# ========================================================================
# FUNÇÃO PRINCIPAL
# ========================================================================

main() {
    # Detectar modo de boot
    detect_boot_mode
    
    # Configuração inicial
    initial_setup
    
    # Configurar disco
    configure_disk
    
    # Particionar disco (modo apropriado)
    if [ "$BOOT_MODE" = "UEFI" ]; then
        partition_disk_uefi
    else
        partition_disk_bios
    fi
    
    # Criar pool e datasets ZFS
    create_zfs_pool
    create_zfs_datasets
    mount_datasets
    
    # Instalar Debian
    install_debian_base
    mount_virtual_filesystems
    
    # Criar scripts de configuração
    create_common_chroot_script
    
    if [ "$BOOT_MODE" = "UEFI" ]; then
        configure_uefi
    else
        configure_bios
    fi
    
    # Executar configuração no chroot
    run_chroot_configuration
    
    # Finalizar
    finalize_installation
    show_completion_message
}

# ========================================================================
# EXECUTAR SCRIPT
# ========================================================================

# Trap para limpeza em caso de erro
trap 'print_error "Erro durante a instalação. Verifique os logs."; exit 1' ERR

# Executar função principal
main



# Salvar o script
# /tmp/install-zfsbootmenu-debian-universal.sh
 
# INFORMAÇÕES DO SCRIPT

# FUNCIONALIDADES

# ✓ Detecção automática de UEFI ou BIOS
# ✓ Particionamento apropriado (GPT para UEFI, MBR para BIOS)
# ✓ Bootloader correto (EFI para UEFI, Syslinux para BIOS)
# ✓ Suporte a criptografia ZFS opcional
# ✓ Mensagens coloridas para melhor UX
# ✓ Tratamento de erros com trap
# ✓ Código modular com funções separadas
# ✓ Configuração interativa do sistema

# ESTRUTURA DO SCRIPT

# 1. detect_boot_mode()             - Detecta UEFI ou BIOS
# 2. initial_setup()                - Configuração inicial comum
# 3. configure_disk()               - Seleção interativa do disco
# 4. partition_disk_uefi()/bios()   - Particionamento
# 5. create_zfs_pool()              - Criação do pool ZFS
# 6. create_zfs_datasets()          - Estrutura de datasets
# 7. mount_datasets()               - Montagem do sistema
# 8. install_debian_base()          - Instalação via debootstrap
# 9. configure_uefi()/bios()        - Configuração do bootloader
# 10. run_chroot_configuration()    - Execução no chroot
# 11. finalize_installation()       - Limpeza e desmontagem
# 12. show_completion_message()     - Mensagem final