#!/bin/bash
set -e

detect_pkg_manager() {
    if command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v zypper >/dev/null 2>&1; then
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

# Função para instalar dependências do host
install_host_deps() {
    local pkg_manager
    pkg_manager=$(detect_pkg_manager)

    echo "   Instalando dependências do host..."

    case "${pkg_manager}" in
    pacman)
        install_pkg "libvirt virt-install virt-manager ebtables iptables dnsmasq guestfs-tools cdrtools"
        ;;
    apt)
        install_pkg "libvirt-daemon libvirt-clients virtinst libguestfs-tools genisoimage qemu-utils ebtables iptables dnsmasq cloud-init"
        ;;
    dnf | yum)
        install_pkg "libvirt virt-install libguestfs-tools genisoimage qemu-img ebtables iptables dnsmasq cloud-init"
        ;;
    zypper)
        install_pkg "libvirt virt-install libguestfs-tools genisoimage qemu-tools ebtables iptables dnsmasq cloud-init"
        ;;
    esac

    # Garante que libvirtd está habilitado e ativo
    systemctl is-active --quiet libvirtd 2>/dev/null || systemctl start libvirtd 2>/dev/null || true
    systemctl enable libvirtd 2>/dev/null || true

    echo "   Dependências do host instaladas com sucesso"
}

VM_NAME="debian-trixie-isobuilder"
IMAGE_DIR="/var/lib/libvirt/images"
IMAGE_PATH="${IMAGE_DIR}/${VM_NAME}.qcow2"

# Detecta o usuário real (mesmo com sudo)
REAL_USER="${SUDO_USER:-${USER}}"
REAL_HOME=$(getent passwd "${REAL_USER}" | cut -d: -f6)
HOST_ISO_DIR="${REAL_HOME}/iso"
VM_MOUNT_DIR="/root/build-iso"
SSH_KEY_PATH="${REAL_HOME}/.ssh/id_rsa.pub"

NETWORK_NAME="default"
NETWORK_BRIDGE="virbr0"
NETWORK_IP="192.168.122.1"
NETWORK_MASK="255.255.255.0"
NETWORK_DHCP_START="192.168.122.100"
NETWORK_DHCP_END="192.168.122.250"
VM_IP="192.168.122.100"
VM_GW="192.168.122.1"
VM_DNS="192.168.122.1"
VM_MAC="52:54:00:ab:cd:01"

VM_USER="debian"
VM_USER_PASS="debian"

CLOUD_INIT_DIR="/tmp/cloud-init-${VM_NAME}"
SSH_PUB_KEY=""

if [ "${EUID}" -ne 0 ]; then
    echo "=> ERRO: Este script deve ser executado como root (sudo)"
    exit 1
fi

echo "===================================================================================="
echo "=> Verificando e instalando dependências do host..."
echo "===================================================================================="

PKG_MANAGER=$(detect_pkg_manager)
echo "   Gerenciador de pacotes detectado: ${PKG_MANAGER}"

# Verifica e instala dependências necessárias
MISSING_DEPS=""

if ! command -v virt-builder >/dev/null 2>&1; then
    echo "   AVISO: virt-builder não encontrado"
    MISSING_DEPS="${MISSING_DEPS} virt-builder"
fi

if ! command -v virt-install >/dev/null 2>&1; then
    echo "   AVISO: virt-install não encontrado"
    MISSING_DEPS="${MISSING_DEPS} virt-install"
fi

if ! command -v virsh >/dev/null 2>&1; then
    echo "   AVISO: virsh não encontrado"
    MISSING_DEPS="${MISSING_DEPS} libvirt-client"
fi

if ! command -v genisoimage >/dev/null 2>&1 && ! command -v mkisofs >/dev/null 2>&1; then
    echo "   AVISO: Ferramenta ISO não encontrada"
    MISSING_DEPS="${MISSING_DEPS} genisoimage"
fi

# Instala dependências se faltarem
if [ -n "${MISSING_DEPS}" ]; then
    echo "   Instalando dependências faltantes:${MISSING_DEPS}..."
    install_host_deps
fi

ISO_TOOL="genisoimage"
if command -v mkisofs >/dev/null 2>&1; then
    ISO_TOOL="mkisofs"
fi

# Garante que libvirtd está ativo
systemctl is-active --quiet libvirtd 2>/dev/null || systemctl start libvirtd 2>/dev/null || true

echo "===================================================================================="
echo "=> Configurando rede do libvirt..."
echo "===================================================================================="

if ! virsh net-info "${NETWORK_NAME}" >/dev/null 2>&1; then
    echo "   Criando rede ${NETWORK_NAME}..."
    virsh net-define /dev/stdin <<EOF
<network>
  <name>${NETWORK_NAME}</name>
  <forward mode='nat'/>
  <bridge name='${NETWORK_BRIDGE}' stp='on' delay='0'/>
  <ip address='${NETWORK_IP}' netmask='${NETWORK_MASK}'>
    <dns>
        <forwarder address='${VM_DNS}'/>
    </dns>
    <dhcp>
      <range start='${NETWORK_DHCP_START}' end='${NETWORK_DHCP_END}'/>
      <host mac='${VM_MAC}' name='${VM_NAME}' ip='${VM_IP}'/>
    </dhcp>
  </ip>
</network>
EOF
    virsh net-start "${NETWORK_NAME}"
    virsh net-autostart "${NETWORK_NAME}"
else
    echo "   Rede ${NETWORK_NAME} já existe"
    if ! virsh net-dumpxml "${NETWORK_NAME}" | grep -q "${VM_MAC}"; then
        echo "   Adicionando reserva de IP para ${VM_NAME}..."
        virsh net-update "${NETWORK_NAME}" add ip-dhcp-host \
            "<host mac='${VM_MAC}' name='${VM_NAME}' ip='${VM_IP}'/>" --live --config
    fi
fi

echo "===================================================================================="
echo "=> Removendo VM e imagem anteriores..."
echo "===================================================================================="

virsh destroy "${VM_NAME}" 2>/dev/null || true
virsh undefine "${VM_NAME}" 2>/dev/null || true
rm -f "${IMAGE_PATH}"

echo "===================================================================================="
echo "=> Criando diretórios necessários..."
echo "===================================================================================="

mkdir -p "${HOST_ISO_DIR}"
mkdir -p "${CLOUD_INIT_DIR}"

echo "===================================================================================="
echo "=> Configurando chave SSH..."
echo "===================================================================================="

if [ ! -f "${SSH_KEY_PATH}" ]; then
    echo "   Gerando nova chave SSH..."
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH%.pub}" -N ""
fi

SSH_PUB_KEY=$(cat "${SSH_KEY_PATH}")

echo "===================================================================================="
echo "=> Criando cloud-init..."
echo "===================================================================================="

cat >"${CLOUD_INIT_DIR}/meta-data" <<EOF
instance-id: ${VM_NAME}-001
local-hostname: ${VM_NAME}
EOF

cat >"${CLOUD_INIT_DIR}/network-config" <<EOF
version: 2
renderer: networkd
ethernets:
    nic-01:
        match:
            macaddress: "${VM_MAC}"
        set-name: enp1s0
        dhcp4: true
        optional: false
        critical: true
        # Garante que a interface seja ativada automaticamente
        wakeonlan: true
        # Adiciona rota padrão automaticamente com DHCP
        gateway4: ${VM_GW}
EOF

cat >"${CLOUD_INIT_DIR}/user-data" <<EOF
#cloud-config
users:
  - name: ${VM_USER}
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    passwd: ${VM_USER_PASS}
    lock_passwd: false
  - name: root
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}
ssh_pwauth: true
disable_root: false
chpasswd:
  list: |
    root:debian
    debian:debian
  expire: false
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
package_update: true
package_upgrade: true

runcmd:
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd
  - mkdir -p /target/root/build-iso
  - echo 'host_iso /root/build-iso virtiofs rw,relatime,nofail 0 0' >> /target/etc/fstab
EOF

echo "   Criando imagem cloud-init ISO..."
if [ "${ISO_TOOL}" = "mkisofs" ]; then
    mkisofs -o "${CLOUD_INIT_DIR}/cidata.iso" -volid cidata -rock -joliet \
        -allow-lowercase -allow-multidot \
        "${CLOUD_INIT_DIR}/user-data" \
        "${CLOUD_INIT_DIR}/meta-data" \
        "${CLOUD_INIT_DIR}/network-config"
else
    genisoimage -o "${CLOUD_INIT_DIR}/cidata.iso" -volid cidata -rock \
        "${CLOUD_INIT_DIR}/user-data" \
        "${CLOUD_INIT_DIR}/meta-data" \
        "${CLOUD_INIT_DIR}/network-config"
fi

echo "===================================================================================="
echo "=> Provisionando imagem Debian com virt-builder..."
echo "===================================================================================="

DEBIAN_TEMPLATE="debian-13"

# if ! virt-builder --list 2> /dev/null | grep -q "${DEBIAN_TEMPLATE}"; then
#     echo "   Template ${DEBIAN_TEMPLATE} não disponível, usando debian-12..."
#     DEBIAN_TEMPLATE="debian-12"
# fi

echo "   Usando template: ${DEBIAN_TEMPLATE}"

virt-builder "${DEBIAN_TEMPLATE}" \
    --size 40G \
    --format qcow2 \
    --output "${IMAGE_PATH}" \
    --hostname "${VM_NAME}" \
    --write '/etc/apt/sources.list:deb http://ftp.br.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://ftp.br.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://ftp.br.debian.org/debian trixie-updates main contrib non-free non-free-firmware' \
    --run-command "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -qqy" \
    --install "sudo,iputils-ping,iproute2,tar,gzip,xz-utils,zstd,lz4,lzop,uuid-runtime,dnsutils,locales,locales-all,keyboard-configuration,console-setup,manpages-pt-br,manpages-pt-br-dev,aspell-pt-br,ibrazilian,wbrazilian,info,info2man,initramfs-tools,kmod,efibootmgr,parted,gdisk,gpg,dirmngr,linux-headers-amd64,linux-image-amd64,grub-efi-amd64-bin,grub-pc-bin,firmware-linux-free,intel-microcode,thermald,msr-tools,firmware-linux-nonfree,os-prober,dkms,dosfstools,mtools,zstd,build-essential,zfs-dkms,zfs-initramfs,zfsutils-linux,zfs-zed,libpam-zfs,libzfsbootenv1linux,libzfslinux-dev,live-build,live-config,live-config-systemd,live-boot,debootstrap,squashfs-tools,xorriso,isolinux,curl,wget,git,ifupdown2,openssh-server,cloud-init,cloud-initramfs-growroot,cloud-initramfs-dyn-netconf,dhcpcd-base,mmdebstrap,rsync,tree,dpkg-dev,screen,ncdu,htop,iotop,iftop,nfs-common,cifs-utils,qemu-guest-agent" \
    --run-command "systemctl enable zfs-zed" \
    --run-command "systemctl enable ssh" \
    --run-command "mkdir -p ${VM_MOUNT_DIR}" \
    --run-command "mkdir -p /root/.ssh && echo '${SSH_PUB_KEY}' > /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys" \
    --timezone "America/Cuiaba" \
    --root-password password:debian

echo "===================================================================================="
echo "=> Criando VM com virt-install..."
echo "===================================================================================="

# virt-install \
#     --name "${VM_NAME}" \
#     --memory 4096 \
#     --vcpus 4 \
#     --os-variant debian13 \
#     --machine q35 \
#     --cpu host-passthrough \
#     --disk path="${IMAGE_PATH}",format=qcow2,bus=virtio,cache=none \
#     --disk path="${CLOUD_INIT_DIR}/cidata.iso",device=cdrom,readonly=on \
#     --network network="${NETWORK_NAME}",model=virtio,mac="${VM_MAC}" \
#     --cloud-init network-config=network-config \
#     --graphics none \
#     --console pty,target_type=serial \
#     --memorybacking source.type=memfd,access.mode=shared \
#     --filesystem type=mount,source="${HOST_ISO_DIR}",target=host_iso,driver.type=virtiofs \
#     --import \
#     --noautoconsole

virt-install \
    --name "${VM_NAME}" \
    --memory 4096 \
    --vcpus 4 \
    --os-variant debian13 \
    --machine q35 \
    --cpu host-passthrough \
    --disk path="${IMAGE_PATH}",format=qcow2,bus=virtio,cache=none \
    --network network="${NETWORK_NAME}",model=virtio,mac="${VM_MAC}" \
    --cloud-init network-config="${CLOUD_INIT_DIR}/network-config" \
    --graphics none \
    --console pty,target_type=serial \
    --memorybacking source.type=memfd,access.mode=shared \
    --filesystem type=mount,source="${HOST_ISO_DIR}",target=host_iso,driver.type=virtiofs \
    --import \
    --noautoconsole

echo "===================================================================================="
echo "=> Configurando firewall para rede libvirt..."
echo "===================================================================================="

# Função para detectar qual firewall está ativo
detect_firewall() {
    # Verifica UFW (Ubuntu/Debian)
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "status: active"; then
        echo "ufw"
        return
    fi

    # Verifica firewalld (RHEL/CentOS/Fedora)
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "firewalld"
        return
    fi

    # Verifica shorewall
    if command -v shorewall >/dev/null 2>&1 && systemctl is-active --quiet shorewall 2>/dev/null; then
        echo "shorewall"
        return
    fi

    # Verifica ferm (Debian)
    if command -v ferm >/dev/null 2>&1 && systemctl is-active --quiet ferm 2>/dev/null; then
        echo "ferm"
        return
    fi

    # Verifica nftables diretamente (regras nativas)
    if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q "."; then
        echo "nftables"
        return
    fi

    # Verifica iptables (legacy ou nft backend)
    if command -v iptables >/dev/null 2>&1; then
        # Verifica se está usando nftables como backend
        if iptables --version 2>/dev/null | grep -qi "nf_tables"; then
            echo "iptables-nft"
        else
            echo "iptables-legacy"
        fi
        return
    fi

    # Sem firewall detectado
    echo "none"
}

# Função para configurar UFW
configure_ufw() {
    echo "   Configurando UFW para libvirt..."

    # Permite DHCP na bridge
    ufw allow in on virbr0 to any port 67 proto udp comment 'libvirt DHCP' 2>/dev/null || true
    ufw allow in on virbr0 to any port 68 proto udp comment 'libvirt DHCP client' 2>/dev/null || true

    # Permite tráfego da rede libvirt
    ufw allow in on virbr0 from "${NETWORK_IP}/24" comment 'libvirt network' 2>/dev/null || true

    # Permite roteamento entre interfaces da bridge
    ufw route allow in on virbr0 out on virbr0 2>/dev/null || true

    # Permite forwarding para NAT
    sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true

    # Recarrega UFW
    ufw reload 2>/dev/null || true

    echo "   UFW configurado com sucesso"
}

# Função para configurar firewalld
configure_firewalld() {
    echo "   Configurando firewalld para libvirt..."

    # Adiciona a interface virbr0 à zona trusted
    firewall-cmd --permanent --zone=trusted --add-interface=virbr0 2>/dev/null || true

    # Permite serviços libvirt
    firewall-cmd --permanent --zone=trusted --add-service=libvirt 2>/dev/null || true

    # Permite DHCP
    firewall-cmd --permanent --zone=trusted --add-port=67/udp 2>/dev/null || true
    firewall-cmd --permanent --zone=trusted --add-port=68/udp 2>/dev/null || true

    # Permite masquerading para NAT
    firewall-cmd --permanent --zone=public --add-masquerade 2>/dev/null || true

    # Se a zona libvirt não existe, cria regras na zona default
    if ! firewall-cmd --get-zones 2>/dev/null | grep -qw libvirt; then
        # Adiciona a rede como source na zona trusted
        firewall-cmd --permanent --zone=trusted --add-source="${NETWORK_IP}/24" 2>/dev/null || true
    fi

    # Recarrega firewalld
    firewall-cmd --reload 2>/dev/null || true

    echo "   firewalld configurado com sucesso"
}

# Função para configurar nftables nativo
configure_nftables() {
    echo "   Configurando nftables para libvirt..."

    # Verifica se o libvirt já criou as regras automaticamente
    # O libvirt cria tabelas LIBVIRT_* automaticamente quando a rede está ativa
    if nft list ruleset 2>/dev/null | grep -q "LIBVIRT_INP\|LIBVIRT_FWI"; then
        echo "   Regras do libvirt já existem (nftables detectado)"
        return 0
    fi

    # Cria tabela e chain para libvirt apenas se não existirem
    nft add table inet libvirt 2>/dev/null || true

    # Chain para INPUT
    nft add chain inet libvirt input \{ type filter hook input priority 0 \; \} 2>/dev/null || true

    # Chain para FORWARD
    nft add chain inet libvirt forward \{ type filter hook forward priority 0 \; \} 2>/dev/null || true

    # Chain para POSTROUTING (NAT)
    nft add chain inet libvirt postrouting \{ type nat hook postrouting priority 100 \; \} 2>/dev/null || true

    # Regras para DHCP
    nft add rule inet libvirt input iifname "virbr0" udp dport 67 accept 2>/dev/null || true
    nft add rule inet libvirt input iifname "virbr0" udp dport 68 accept 2>/dev/null || true

    # Regras para FORWARD
    nft add rule inet libvirt forward iifname "virbr0" accept 2>/dev/null || true
    nft add rule inet libvirt forward oifname "virbr0" accept 2>/dev/null || true

    # Regra para MASQUERADE (NAT)
    nft add rule inet libvirt postrouting ip saddr "${NETWORK_IP}/24" ip daddr != "${NETWORK_IP}/24" masquerade 2>/dev/null || true

    echo "   nftables configurado com sucesso"
}

# Função para configurar iptables (legacy ou nft backend)
configure_iptables() {
    echo "   Configurando iptables para libvirt..."

    # FORWARD chain
    iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
        iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -C FORWARD -i virbr0 -j ACCEPT 2>/dev/null ||
        iptables -A FORWARD -i virbr0 -j ACCEPT
    iptables -C FORWARD -o virbr0 -j ACCEPT 2>/dev/null ||
        iptables -A FORWARD -o virbr0 -j ACCEPT

    # NAT (MASQUERADE)
    iptables -t nat -C POSTROUTING -s "${NETWORK_IP}/24" ! -d "${NETWORK_IP}/24" -j MASQUERADE 2>/dev/null ||
        iptables -t nat -A POSTROUTING -s "${NETWORK_IP}/24" ! -d "${NETWORK_IP}/24" -j MASQUERADE

    # INPUT chain - DHCP
    iptables -C INPUT -i virbr0 -p udp --dport 67 -j ACCEPT 2>/dev/null ||
        iptables -A INPUT -i virbr0 -p udp --dport 67 -j ACCEPT
    iptables -C INPUT -i virbr0 -p udp --dport 68 -j ACCEPT 2>/dev/null ||
        iptables -A INPUT -i virbr0 -p udp --dport 68 -j ACCEPT

    # INPUT chain - tráfego da rede libvirt
    iptables -C INPUT -i virbr0 -s "${NETWORK_IP}/24" -j ACCEPT 2>/dev/null ||
        iptables -A INPUT -i virbr0 -s "${NETWORK_IP}/24" -j ACCEPT

    # Salva regras (persistência)
    if command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables 2>/dev/null || true
        iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
    fi

    echo "   iptables configurado com sucesso"
}

# Função para configurar shorewall
configure_shorewall() {
    echo "   Configurando shorewall para libvirt..."

    # Shorewall usa arquivos de configuração em /etc/shorewall/
    # Adiciona regras dinamicamente via shorewall commands

    # Verifica se o arquivo de interfaces existe
    if [ -f /etc/shorewall/interfaces ]; then
        grep -q "virbr0" /etc/shorewall/interfaces 2>/dev/null ||
            echo "net     virbr0          detect          dhcp" >>/etc/shorewall/interfaces
    fi

    # Adiciona regras para DHCP
    if [ -f /etc/shorewall/rules ]; then
        grep -q "virbr0.*67" /etc/shorewall/rules 2>/dev/null ||
            echo 'ACCEPT          virbr0          "${FW}"             udp     67,68' >>/etc/shorewall/rules
    fi

    # Permite forwarding
    if [ -f /etc/shorewall/policy ]; then
        grep -q "virbr0.*all" /etc/shorewall/policy 2>/dev/null ||
            echo "virbr0          all             ACCEPT" >>/etc/shorewall/policy
    fi

    # Recarrega shorewall
    shorewall reload 2>/dev/null || shorewall restart 2>/dev/null || true

    echo "   shorewall configurado com sucesso"
}

# Função para configurar ferm
configure_ferm() {
    echo "   Configurando ferm para libvirt..."

    # Ferm usa arquivos de configuração em /etc/ferm/
    FERM_CONF="/etc/ferm/ferm.conf"

    if [ -f "${FERM_CONF}" ]; then
        # Adiciona regras para libvirt se não existirem
        if ! grep -q "virbr0" "${FERM_CONF}" 2>/dev/null; then
            cat >>"${FERM_CONF}" <<'FERM_RULES'

# Libvirt network rules
chain INPUT {
    interface virbr0 proto udp dport (67 68) ACCEPT;
    interface virbr0 saddr 192.168.122.0/24 ACCEPT;
}
chain FORWARD {
    interface virbr0 ACCEPT;
    outerface virbr0 ACCEPT;
}
chain POSTROUTING {
    saddr 192.168.122.0/24 daddr ! 192.168.122.0/24 MASQUERADE;
}
FERM_RULES
        fi

        # Recarrega ferm
        ferm "${FERM_CONF}" 2>/dev/null || systemctl reload ferm 2>/dev/null || true
    fi

    echo "   ferm configurado com sucesso"
}

# Detecta e configura o firewall apropriado
FIREWALL_TYPE=$(detect_firewall)
echo "   Firewall detectado: ${FIREWALL_TYPE}"

case "${FIREWALL_TYPE}" in
ufw)
    configure_ufw
    ;;
firewalld)
    configure_firewalld
    ;;
nftables)
    configure_nftables
    ;;
iptables-nft | iptables-legacy)
    configure_iptables
    ;;
shorewall)
    configure_shorewall
    ;;
ferm)
    configure_ferm
    ;;
none)
    echo "   Nenhum firewall ativo detectado. Configurando iptables básico..."
    configure_iptables
    ;;
*)
    echo "   Firewall desconhecido. Tentando configuração genérica..."
    configure_iptables
    ;;
esac

# Garante que a bridge está ativa
ip link set virbr0 up 2>/dev/null || true

VNET_DEV=$(ip link show | grep -oP 'vnet[0-9]+' | tail -1)
if [ -n "${VNET_DEV}" ]; then
    ip link set "${VNET_DEV}" master virbr0 2>/dev/null || true
fi

echo "===================================================================================="
echo "=> Aguardando VM iniciar e obter IP..."
echo "===================================================================================="

sleep 15

for i in {1..30}; do
    # DEBUG: Verificar status da interface na VM a cada 5 tentativas
    if [ $((i % 5)) -eq 0 ]; then
        echo "   [DEBUG] Verificando interfaces da VM (tentativa ${i})..."
        INTERFACES=$(virsh qemu-agent-command "${VM_NAME}" '{"execute":"guest-network-get-interfaces"}' 2>/dev/null | grep -oP '"name":"[^"]+' | grep -v lo || echo "Sem acesso ao qemu-guest-agent")
        echo "   [DEBUG] Interfaces encontradas: ${INTERFACES}"

        # Verificar se há endereços IP atribuídos
        IP_ADDRS=$(virsh qemu-agent-command "${VM_NAME}" '{"execute":"guest-network-get-interfaces"}' 2>/dev/null | grep -oP '"ip-address":\s*"[^"]+' || echo "Nenhum IP encontrado")
        echo "   [DEBUG] Endereços IP: ${IP_ADDRS}"
    fi

    VM_IP_OBTIDO=$(virsh domifaddr "${VM_NAME}" 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || echo "")
    if [ -n "${VM_IP_OBTIDO}" ]; then
        echo "   VM obtendo IP: ${VM_IP_OBTIDO}"
        break
    fi

    if [ "${i}" -eq 15 ]; then
        echo "   Tentando configurar IP via QEMU agent..."

        virsh qemu-agent-command "${VM_NAME}" '{"execute":"guest-exec","arguments":{"path":"dhclient","arg":["-v","enp1s0"],"capture-output":true}}' 2>/dev/null

        sleep 5

        INTERFACE=$(virsh qemu-agent-command "${VM_NAME}" '{"execute":"guest-network-get-interfaces"}' 2>/dev/null | grep -oP '"name":"[^"]+' | grep -v lo | head -1 | cut -d'"' -f4)

        if [ -n "${INTERFACE}" ]; then
            virsh qemu-agent-command "${VM_NAME}" "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"ip\",\"arg\":[\"addr\",\"add\",\"${VM_IP}/24\",\"dev\",\"${INTERFACE}\"],\"capture-output\":true}}" 2>/dev/null
            virsh qemu-agent-command "${VM_NAME}" "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"ip\",\"arg\":[\"link\",\"set\",\"${INTERFACE}\",\"up\"],\"capture-output\":true}}" 2>/dev/null
            virsh qemu-agent-command "${VM_NAME}" "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"ip\",\"arg\":[\"route\",\"add\",\"default\",\"via\",\"${VM_GW}\"],\"capture-output\":true}}" 2>/dev/null
            VM_IP_OBTIDO="${VM_IP}"
        fi
    fi

    echo "   Aguardando... (${i}/30)"
    sleep 2
done

# DEBUG: Se não obteve IP, forçar ativação da interface
if [ -z "${VM_IP_OBTIDO}" ]; then
    echo "   [DEBUG] IP não obtido. Tentando forçar interface up..."
    INTERFACE=$(virsh qemu-agent-command "${VM_NAME}" '{"execute":"guest-network-get-interfaces"}' 2>/dev/null | grep -oP '"name":"[^"]+' | grep -v lo | head -1 | cut -d'"' -f4)
    if [ -n "${INTERFACE}" ]; then
        echo "   [DEBUG] Forçando interface ${INTERFACE} up..."
        virsh qemu-agent-command "${VM_NAME}" "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"ip\",\"arg\":[\"link\",\"set\",\"${INTERFACE}\",\"up\"],\"capture-output\":true}}" 2>/dev/null
        virsh qemu-agent-command "${VM_NAME}" "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"dhclient\",\"arg\":[\"-v\",\"${INTERFACE}\"],\"capture-output\":true}}" 2>/dev/null
        sleep 3
        VM_IP_OBTIDO=$(virsh domifaddr "${VM_NAME}" 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || echo "")
        echo "   [DEBUG] IP obtido após forçar: ${VM_IP_OBTIDO}"
    fi
fi

echo "===================================================================================="
echo "=> Verificando status da VM..."
echo "===================================================================================="

if virsh dominfo "${VM_NAME}" 2>/dev/null | grep -q "executando\|running"; then
    VM_IP_OBTIDO=$(virsh domifaddr "${VM_NAME}" 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || echo "${VM_IP}")

    echo "===================================================================================="
    echo "=> Provisionamento concluído com sucesso!"
    echo "===================================================================================="
    echo ""
    echo "   Rede: ${NETWORK_NAME} (${NETWORK_IP}/24)"
    echo "   VM IP: ${VM_IP_OBTIDO}"
    echo "   Acesse: ssh debian@${VM_IP_OBTIDO}"
    echo "   SSH root: ssh root@${VM_IP_OBTIDO}"
    echo "   Senha: debian"
    echo ""
    echo "   Para acessar a VM: ssh debian@${VM_IP_OBTIDO}"
    echo ""
else
    echo "=> ERRO: VM não está executando"
    virsh dominfo "${VM_NAME}"
    exit 1
fi

rm -rf "${CLOUD_INIT_DIR}"
