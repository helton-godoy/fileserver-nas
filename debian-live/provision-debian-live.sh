#!/bin/bash
set -e

detect_pkg_manager() {
    if command -v pacman > /dev/null 2>&1; then
        echo "pacman"
    elif command -v apt-get > /dev/null 2>&1; then
        echo "apt"
    elif command -v dnf > /dev/null 2>&1; then
        echo "dnf"
    elif command -v yum > /dev/null 2>&1; then
        echo "yum"
    elif command -v zypper > /dev/null 2>&1; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

install_pkg() {
    local pkg_manager
    pkg_manager=$(detect_pkg_manager)

    case "${pkg_manager}" in
        pacman)
            pacman -S --noconfirm "$1"
            ;;
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y "$1"
            ;;
        dnf | yum)
            dnf install -y "$1" || yum install -y "$1"
            ;;
        zypper)
            zypper install -y "$1"
            ;;
        *)
            echo "   ERRO: Gerenciador de pacotes não suportado"
            exit 1
            ;;
    esac
}

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
BUILD_DIR="${PROJECT_DIR}"

echo "===================================================================================="
echo "=> Criando ISO Live Debian Trixie com ZFS"
echo "===================================================================================="

if [ "$EUID" -ne 0 ]; then
    echo "=> ERRO: Este script deve ser executado como root (sudo)"
    exit 1
fi

PKG_MANAGER=$(detect_pkg_manager)
echo "   Gerenciador de pacotes detectado: $PKG_MANAGER"

echo "===================================================================================="
echo "=> Verificando dependências..."
echo "===================================================================================="

if ! command -v lb > /dev/null 2>&1; then
    echo "   Instalando live-build..."
    install_pkg "live-build live-config"
fi

echo "===================================================================================="
echo "=> Criando configuração live-build..."
echo "===================================================================================="

cd "${PROJECT_DIR}"

lb config \
    --distribution trixie \
    --binary-image hybrid \
    --bootappend-live "boot=live components locale=pt_BR.UTF-8 keyboard-layouts=br" \
    --debian-installer false \
    --archive-areas "main contrib non-free non-free-firmware" \
    --mirror-bootstrap "http://ftp.br.debian.org/debian" \
    --mirror-chroot "http://ftp.br.debian.org/debian" \
    --mirror-binary "http://ftp.br.debian.org/debian" \
    --firmware-binary true \
    --iso-publisher "Debian ZFS Installer,debian-zfs@example.com" \
    --iso-volume "Debian Trixie ZFS" \
    --chroot-filesystem squashfs \
    --bootloader syslinux,grub-pc \
    --binary-filesystem fat32 \
    --source false \
    2>&1

echo "===================================================================================="
echo "=> Criando lista de pacotes..."
echo "===================================================================================="

cat > config/package-lists/zfs.list.chroot << 'EOF'
# Base system
live-boot
live-config
live-tools
systemd
udev
dbus

# ZFS
zfsutils-linux
zfs-dkms
zfs-initramfs

# Installation tools
debootstrap
gdisk
parted
gpg
dirmngr
gnupg

# Network
ifupdown2
isc-dhcp-client
openssh-client
openssh-server
iputils-ping
net-tools
dnsutils

# Utilities
vim-tiny
sudo
curl
wget
git
htop
rsync
tar
gzip
xz-utils
zstd
uuid-runtime
locales
keyboard-configuration
console-setup
initramfs-tools
initramfs-tools-bin
kmod
efibootmgr
grub-efi-amd64
grub-pc
grub-pc-bin
os-prober

# Firmware
firmware-linux-free
firmware-linux-nonfree
EOF

echo "===================================================================================="
echo "=> Configurando repositórios brasileiros..."
echo "===================================================================================="

mkdir -p config/includes.chroot/etc/apt

cat > config/includes.chroot/etc/apt/sources.list << 'EOF'
deb http://ftp.br.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://ftp.br.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

echo "===================================================================================="
echo "=> Configurando rede com IP fixo..."
echo "===================================================================================="

mkdir -p config/includes.chroot/etc/network

cat > config/includes.chroot/etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 192.168.1.10/24
    gateway 192.168.1.1
    dns-nameservers 192.168.1.1
EOF

echo "===================================================================================="
echo "=> Configurando SSH..."
echo "===================================================================================="

mkdir -p config/includes.chroot/etc/ssh

cat > config/includes.chroot/etc/ssh/sshd_config << 'EOF'
Port 22
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AcceptEnv LANG LC_*

Subsystem sftp /usr/lib/openssh/sftp-server
EOF

cat > config/includes.chroot/etc/ssh/ssh_config << 'EOF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

echo "===================================================================================="
echo "=> Criando script de instalação ZFS..."
echo "===================================================================================="

mkdir -p config/includes.chroot/usr/local/bin

cat > config/includes.chroot/usr/local/bin/install-zfs << 'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

DEFAULT_IP="192.168.1.10/24"
DEFAULT_GW="192.168.1.1"
DEFAULT_DNS="192.168.1.1"
DEFAULT_HOSTNAME="debian-zfs"
DEFAULT_USERNAME="debian"
DEFAULT_PASSWORD="debian"
DEFAULT_BOOT_POOL_SIZE="2G"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << USAGE
Usage: $0 [OPTIONS]

Options:
    --disk PATH              Disco para instalação (ex: /dev/sda)
    --hostname NAME          Nome do host (default: $DEFAULT_HOSTNAME)
    --ip CIDR               Endereço IP (default: $DEFAULT_IP)
    --gateway IP            Gateway (default: $DEFAULT_GW)
    --dns DNS               Servidores DNS, separados por vírgula (default: $DEFAULT_DNS)
    --username NAME         Usuário padrão (default: $DEFAULT_USERNAME)
    --password PASS         Senha do usuário (default: $DEFAULT_PASSWORD)
    --boot-pool-size SIZE   Tamanho do boot pool (default: $DEFAULT_BOOT_POOL_SIZE)
    --encrypt               Habilitar criptografia ZFS
    --help                  Mostrar esta ajuda

Exemplo:
    $0 --disk /dev/disk/by-id/ata-xxxx --hostname myserver
USAGE
    exit 0
}

parse_args() {
    ENCRYPT="no"
    while [[ $# -gt 0 ]]; do
        case $1 in
        --disk)
            DISK="$2"
            shift 2
            ;;
        --hostname)
            HOSTNAME="$2"
            shift 2
            ;;
        --ip)
            IP_ADDR="$2"
            shift 2
            ;;
        --gateway)
            GATEWAY="$2"
            shift 2
            ;;
        --dns)
            DNS_SERVERS="$2"
            shift 2
            ;;
        --username)
            USERNAME="$2"
            shift 2
            ;;
        --password)
            PASSWORD="$2"
            shift 2
            ;;
        --boot-pool-size)
            BOOT_POOL_SIZE="$2"
            shift 2
            ;;
        --encrypt)
            ENCRYPT="yes"
            shift
            ;;
        --help)
            usage
            ;;
        *)
            log_error "Opção desconhecida: $1"
            usage
            ;;
        esac
    done

    DISK="${DISK:-}"
    HOSTNAME="${HOSTNAME:-$DEFAULT_HOSTNAME}"
    IP_ADDR="${IP_ADDR:-$DEFAULT_IP}"
    GATEWAY="${GATEWAY:-$DEFAULT_GW}"
    DNS_SERVERS="${DNS_SERVERS:-$DEFAULT_DNS}"
    USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
    PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
    BOOT_POOL_SIZE="${BOOT_POOL_SIZE:-$DEFAULT_BOOT_POOL_SIZE}"
}

validate() {
    if [[ -z "$DISK" ]]; then
        log_error "Parâmetro --disk é obrigatório"
        exit 1
    fi

    if [[ ! -b "$DISK" ]]; then
        log_error "Disco não encontrado: $DISK"
        exit 1
    fi

    if [[ "$EUID" -ne 0 ]]; then
        log_error "Este script deve ser executado como root"
        exit 1
    fi
}

detect_uefi() {
    if [[ -d /sys/firmware/efi ]]; then
        log_info "Modo UEFI detectado"
        UEFI="yes"
    else
        log_info "Modo BIOS detectado"
        UEFI="no"
    fi
}

configure_network() {
    log_info "Configurando rede..."

    local ip_without_prefix="${IP_ADDR%%/*}"
    local prefix="${IP_ADDR##*/}"
    local gateway_short="${GATEWAY}"

    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address ${ip_without_prefix}/${prefix}
    gateway ${gateway_short}
    dns-nameservers ${DNS_SERVERS//,/ }
EOF

    ip link set eth0 up || true
    ip addr flush dev eth0 || true
    ip addr add "${IP_ADDR}" dev eth0 || true
    ip route add default via "${GATEWAY}" || true

    echo "nameserver ${DNS_SERVERS//,/ }" > /etc/resolv.conf

    log_info "Rede configurada: ${IP_ADDR}"
}

configure_repositories() {
    log_info "Configurando repositórios..."

    cat > /etc/apt/sources.list << EOF
deb http://ftp.br.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://ftp.br.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://ftp.br.debian.org/debian trixie-security main contrib non-free non-free-firmware
EOF

    apt-get update -qq
    log_info "Repositórios configurados"
}

install_zfs() {
    log_info "Instalando ZFS no ambiente live..."

    apt-get install -y -qq \
        debootstrap \
        gdisk \
        zfsutils-linux \
        zfs-dkms \
        zfs-initramfs \
        kmod || true

    log_info "ZFS instalado"
}

clear_disk() {
    log_info "Limpando disco: $DISK"

    swapoff --all 2>/dev/null || true

    mdadm --stop --scan 2>/dev/null || true

    wipefs -a "$DISK" 2>/dev/null || true
    mdadm --zero-superblock --force "$DISK" 2>/dev/null || true

    log_info "Disco limpo"
}

create_partitions() {
    log_info "Criando partições..."

    local disk_id
    disk_id="$(basename "$DISK")"

    sgdisk --zap-all "$DISK"

    if [[ "$UEFI" == "yes" ]]; then
        log_info "Criando partições para UEFI..."
        sgdisk -n 1:0:+1M -t 1:EF02 -c 1:"BIOS boot" "$DISK"
        sgdisk -n 2:0:+512M -t 2:EF00 -c 2:"EFI System" "$DISK"
        sgdisk -n 3:0:+${BOOT_POOL_SIZE} -t 3:BF01 -c 3:"Boot pool" "$DISK"
        sgdisk -n 4:0:0 -t 3:BF01 -c 4:"Root pool" "$DISK"

        ESP_PART="${disk_id}-part2"
        BOOT_PART="${disk_id}-part3"
        ROOT_PART="${disk_id}-part4"
    else
        log_info "Criando partições para BIOS..."
        sgdisk -n 1:0:+1M -t 1:EF02 -c 1:"BIOS boot" "$DISK"
        sgdisk -n 2:0:+${BOOT_POOL_SIZE} -t 3:BF01 -c 2:"Boot pool" "$DISK"
        sgdisk -n 3:0:0 -t 3:BF01 -c 3:"Root pool" "$DISK"

        BOOT_PART="${disk_id}-part2"
        ROOT_PART="${disk_id}-part3"
    fi

    partprobe "$DISK"
    sleep 2

    log_info "Partições criadas"
}

create_zfs_pools() {
    log_info "Criando ZFS pools..."

    local boot_devices="/dev/disk/by-id/${BOOT_PART}"
    local root_devices="/dev/disk/by-id/${ROOT_PART}"

    if [[ "$UEFI" == "yes" ]]; then
        mkfs.fat -n EFI /dev/disk/by-id/${ESP_PART} || true
    fi

    zpool create -f \
        -o ashift=12 \
        -o cachefile=/tmp/zpool.cache \
        -o compatibility=grub2 \
        -m none -R /mnt \
        bpool \
        "$boot_devices"

    if [[ "$ENCRYPT" == "yes" ]]; then
        zpool create -f \
            -o ashift=12 \
            -o cachefile=/tmp/zpool.cache \
            -m none -R /mnt \
            -O encryption=aes-256-gcm \
            -O keylocation=prompt \
            -O keyformat=passphrase \
            rpool \
            "$root_devices"
    else
        zpool create -f \
            -o ashift=12 \
            -o cachefile=/tmp/zpool.cache \
            -m none -R /mnt \
            rpool \
            "$root_devices"
    fi

    zfs set compression=lz4 rpool
    zfs set atime=off rpool
    zfs set mountpoint=/ rpool

    zfs create -o mountpoint=/boot bpool/boot

    log_info "ZFS pools criados"
}

create_datasets() {
    log_info "Criando datasets..."

    zfs create -o canmount=off -o setuid=off -o readonly=off bpool/boot/grub
    zfs create -o canmount=off -o setuid=off -o readonly=off bpool/boot/grub/x86_64-pc
    zfs create -o canmount=off -o setuid=off -o readonly=off bpool/boot/grub/x86_64-efi

    zfs create -o canmount=noauto -o setuid=off -o readonly=off -o mountpoint=/boot/efi rpool/boot/efi
    zfs mount rpool/boot/efi || true

    zfs create                                  rpool/var
    zfs create -o canmount=off                  rpool/var/lib
    zfs create                                  rpool/var/log
    zfs create                                  rpool/home
    zfs create -o mountpoint=/root              rpool/root

    log_info "Datasets criados"
}

install_debian() {
    log_info "Instalando Debian base..."

    DEBIAN_FRONTEND=noninteractive debootstrap \
        --variant=minbase \
        --include="gnupg,live-boot,live-config,live-tools,systemd,udev,dbus" \
        trixie \
        /mnt \
        http://ftp.br.debian.org/debian

    log_info "Debian base instalado"
}

configure_system() {
    log_info "Configurando sistema..."

    cp /tmp/zpool.cache /mnt/etc/zfs/zpool.cache

    cat > /mnt/etc/apt/sources.list << EOF
deb http://ftp.br.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://ftp.br.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://ftp.br.debian.org/debian trixie-security main contrib non-free non-free-firmware
EOF

    mount -t proc /proc /mnt/proc
    mount -t sysfs /sys /mnt/sys
    mount -o bind /dev /mnt/dev

    cat > /mnt/etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address ${IP_ADDR%%/*}/${IP_ADDR##*/}
    gateway ${GATEWAY}
    dns-nameservers ${DNS_SERVERS//,/ }
EOF

    echo "${HOSTNAME}" > /mnt/etc/hostname

    cat > /mnt/etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    chroot /mnt /bin/bash -c "apt-get update -qq"
    chroot /mnt /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        linux-image-amd64 \
        zfsutils-linux \
        zfs-dkms \
        zfs-initramfs \
        grub-efi-amd64 \
        grub-pc \
        grub-pc-bin \
        os-prober \
        openssh-server \
        sudo \
        vim-tiny \
        ifupdown2 \
        iputils-ping \
        net-tools \
        dnsutils \
        curl \
        wget \
        git \
        rsync \
        tar \
        gzip \
        xz-utils \
        zstd \
        uuid-runtime \
        locales \
        keyboard-configuration \
        console-setup \
        initramfs-tools \
        kmod \
        efibootmgr \
        parted \
        gdisk \
        gpg \
        dirmngr"

    chroot /mnt /bin/bash -c "echo 'pt_BR.UTF-8 UTF-8' > /etc/locale.gen"
    chroot /mnt /bin/bash -c "locale-gen"

    chroot /mnt /bin/bash -c "ln -sf /usr/share/zoneinfo/America/Cuiaba /etc/localtime"

    chroot /mnt /bin/bash -c "echo 'KEYMAP=br-abnt2' > /etc/vconsole.conf"

    echo "LANG=pt_BR.UTF-8" > /mnt/etc/default/locale

    chroot /mnt /bin/bash -c "useradd -m -s /bin/bash -G sudo ${USERNAME}"
    echo "${USERNAME}:${PASSWORD}" | chroot /mnt /bin/bash -c "chpasswd"
    echo "root:${PASSWORD}" | chroot /mnt /bin/bash -c "chpasswd"

    mkdir -p /mnt/root/.ssh
    chmod 700 /mnt/root/.ssh
    touch /mnt/root/.ssh/authorized_keys
    chmod 600 /mnt/root/.ssh/authorized_keys

    cat > /mnt/etc/ssh/sshd_config << EOF
Port 22
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

    cat > /mnt/etc/ssh/ssh_config << EOF
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

    cat > /mnt/etc/fstab << EOF
/dev/by-id/${ROOT_PART} / zfs defaults 0 0
EOF

    if [[ "$UEFI" == "yes" ]]; then
        echo "/dev/disk/by-id/${ESP_PART} /boot/efi vfat defaults 0 2" >> /mnt/etc/fstab
    fi

    log_info "Sistema configurado"
}

install_grub() {
    log_info "Instalando GRUB..."

    if [[ "$UEFI" == "yes" ]]; then
        mount /dev/disk/by-id/${ESP_PART} /mnt/boot/efi || true

        chroot /mnt /bin/bash -c "update-grub"
        chroot /mnt /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Debian --recheck --no-nvram" || true

        umount /mnt/boot/efi || true
    else
        chroot /mnt /bin/bash -c "grub-install ${DISK}"
    fi

    chroot /mnt /bin/bash -c "update-grub"

    log_info "GRUB instalado"
}

generate_initramfs() {
    log_info "Gerando initramfs..."

    chroot /mnt /bin/bash -c "update-initramfs -u"

    log_info "Initramfs gerado"
}

cleanup() {
    log_info "Limpando..."

    umount /mnt/proc /mnt/sys /mnt/dev 2>/dev/null || true
    umount /mnt/boot/efi 2>/dev/null || true
    umount /mnt 2>/dev/null || true

    zpool export -a 2>/dev/null || true

    log_info "Instalação concluída!"
    log_info "Hostname: ${HOSTNAME}"
    log_info "IP: ${IP_ADDR}"
    log_info "Usuário: ${USERNAME}"
    log_info "Senha: ${PASSWORD}"
}

main() {
    log_info "========================================"
    log_info "  Instalador ZFS - Debian Trixie"
    log_info "========================================"

    parse_args "$@"
    validate
    detect_uefi
    configure_network
    configure_repositories
    install_zfs
    clear_disk
    create_partitions
    create_zfs_pools
    create_datasets
    install_debian
    configure_system
    install_grub
    generate_initramfs
    cleanup

    log_info "========================================"
    log_info "  INSTALAÇÃO CONCLUÍDA!"
    log_info "========================================"
    log_info "Reinicie o sistema para bootar do disco"
}

main "$@"
SCRIPT_EOF

chmod +x config/includes.chroot/usr/local/bin/install-zfs

echo "===================================================================================="
echo "=> Criando script de menu de instalação..."
echo "===================================================================================="

cat > config/includes.chroot/usr/local/bin/install << 'MENU_EOF'
#!/bin/bash
echo "========================================"
echo "  Debian Trixie ZFS Installer"
echo "========================================"
echo ""
echo "Este instalador configurará ZFS root automaticamente."
echo ""
echo "Uso:"
echo "  sudo install-zfs --disk /dev/disk/by-id/ata-xxxx"
echo ""
echo "Opções:"
echo "  --disk PATH           Disco para instalação (obrigatório)"
echo "  --hostname NAME       Nome do host (default: debian-zfs)"
echo "  --ip CIDR            Endereço IP (default: 192.168.1.10/24)"
echo "  --gateway IP         Gateway (default: 192.168.1.1)"
echo "  --dns DNS            DNS servers (default: 8.8.8.8,8.8.4.4)"
echo "  --username NAME      Usuário (default: debian)"
echo "  --password PASS      Senha (default: debian)"
echo "  --boot-pool-size SIZE Tamanho boot pool (default: 2G)"
echo ""
echo "Exemplo completo:"
echo "  sudo install-zfs \\"
echo "    --disk /dev/disk/by-id/ata-WDC_WD10EZEX-xxxx \\"
echo "    --hostname myserver \\"
echo "    --ip 192.168.1.100/24 \\"
echo "    --gateway 192.168.1.1"
echo ""
MENU_EOF

chmod +x config/includes.chroot/usr/local/bin/install

echo "===================================================================================="
echo "=> Configurando locale e keyboard..."
echo "===================================================================================="

mkdir -p config/includes.chroot/etc/default

cat > config/includes.chroot/etc/default/locale << 'EOF'
LANG=pt_BR.UTF-8
LANGUAGE=pt_BR.UTF-8
LC_ALL=pt_BR.UTF-8
EOF

cat > config/includes.chroot/etc/default/console-setup << 'EOF'
CHARMAP=UTF-8
CODETABLE=br-abnt2
FONTFACE=Terminus
FONTSIZE=16x32
ACTIVE=1
EOF

cat > config/includes.chroot/etc/vconsole.conf << 'EOF'
KEYMAP=br-abnt2
FONT=
EOF

echo "===================================================================================="
echo "=> Construindo ISO..."
echo "===================================================================================="

lb build 2>&1 | tee "${PROJECT_DIR}/build.log"

ISO_FILE="$(ls -t *.iso 2> /dev/null | head -1)"

if [[ -f ${ISO_FILE} ]]; then
    echo "===================================================================================="
    echo "=> ISO criada com sucesso!"
    echo "===================================================================================="
    echo ""
    echo "Arquivo: ${ISO_FILE}"
    echo "Tamanho: $(du -h "${ISO_FILE}" | cut -f1)"
    echo ""
    echo "Para testar:"
    echo "  qemu-system-x86_64 -m 4096 -cdrom ${ISO_FILE} -boot d"
    echo ""
    echo "Para gravar em USB:"
    echo "  sudo dd if=${ISO_FILE} of=/dev/sdX bs=4M status=progress"
else
    echo "ERRO: ISO não foi criada"
    exit 1
fi
