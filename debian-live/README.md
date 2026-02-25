# Debian Trixie ZFS Live ISO

## Visão Geral

Este projeto cria uma ISO live do Debian Trixie personalizada para instalação de Debian com ZFS root em máquinas físicas ou virtuais.

## Características

- **Live ISO**: Bootável sem instalação
- **ZFS Root**: Suporte completo a ZFS como sistema de arquivos root
- **BIOS + UEFI**: Suporte a ambos os modos de boot
- **IP Fixo**: Configuração de rede com IP estático
- **Sem Criptografia**: Instalação sem ZFS encryption
- **Automático**: Instalação não-interativa

## Requisitos

### Build (máquina que constrói a ISO)

- Debian/Ubuntu ou Arch Linux
- 20GB+ espaço livre em disco
- 4GB+ RAM
- Acesso à internet (para baixar pacotes)

### Runtime (máquina que roda a ISO)

- x86_64 (AMD64)
- 4GB+ RAM (recomendado para ZFS)
- Disco dedicado (todos os dados serão perdidos)

## Uso

### 1. Construir a ISO

```bash
# Instalar dependências
make install-deps

# Construir a ISO
make build
```

A ISO será criada em: `debian-live/live-image-amd64.hybrid.iso`

### 2. Testar a ISO

```bash
# Testar com KVM (recomendado)
make test

# Testar sem KVM (mais lento)
make test-no-kvm
```

### 3. Gravar em USB

```bash
# Identificar o dispositivo USB
sudo fdisk -l

# Gravar a ISO (ATENÇÃO: escolha o dispositivo correto!)
sudo dd if=debian-live/live-image-amd64.hybrid.iso of=/dev/sdX bs=4M status=progress
```

### 4. Bootar e Instalar

#### Boot pela ISO

1. Configure o BIOS/UEFI para bootar da USB
2. Selecione "Live" no menu de boot

#### Executar a Instalação

```bash
# Lista discos disponíveis
ls -la /dev/disk/by-id/

# Executar instalação (exemplo)
sudo install-zfs \
    --disk /dev/disk/by-id/ata-WDC_WD10EZEX-xxxx \
    --hostname debian-zfs \
    --ip 192.168.1.10/24 \
    --gateway 192.168.1.1 \
    --dns 8.8.8.8,8.8.4.4 \
    --username debian \
    --password minha_senha
```

## Opções do Script de Instalação

| Opção | Descrição | Default |
|-------|-----------|---------|
| `--disk` | Disco para instalação (obrigatório) | - |
| `--hostname` | Nome do host | debian-zfs |
| `--ip` | Endereço IP (CIDR) | 192.168.1.10/24 |
| `--gateway` | Gateway padrão | 192.168.1.1 |
| `--dns` | Servidores DNS (separados por vírgula) | 8.8.8.8,8.8.4.4 |
| `--username` | Usuário padrão | debian |
| `--password` | Senha do usuário | debian |
| `--boot-pool-size` | Tamanho do boot pool | 2G |
| `--encrypt` | Habilitar criptografia ZFS | não |

## Estrutura do Projeto

```
debian-live/
├── provision-debian-live.sh  # Script principal de build
├── Makefile                  # Automação do build
├── config/                  # Configuração live-build
│   ├── auto/config
│   ├── package-lists/
│   │   └── zfs.list.chroot
│   └── includes.chroot/
│       ├── etc/
│       │   ├── apt/sources.list
│       │   ├── network/interfaces
│       │   └── ssh/sshd_config
│       └── usr/local/bin/
│           ├── install-zfs    # Script de instalação
│           └── install       # Menu de ajuda
└── README.md
```

## Detalhes Técnicos

### Particionamento (BIOS + UEFI)

| Partição | Tipo | Tamanho | Sistema |
|----------|------|---------|---------|
| 1 | BIOS Boot | 1MB | - |
| 2 | EFI System | 512MB | FAT32 |
| 3 | Boot Pool | 2GB | ZFS |
| 4 | Root Pool | Resto | ZFS |

### ZFS Pools

- **bpool**: Boot pool (contém /boot)
- **rpool**: Root pool (contém /)

### Repositórios BR

```
deb http://ftp.br.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://ftp.br.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://ftp.br.debian.org/debian trixie-security main contrib non-free non-free-firmware
```

### Pacotes Incluídos

- ZFS (zfsutils-linux, zfs-dkms, zfs-initramfs)
- Rede (ifupdown2, isc-dhcp-client, openssh-server)
- Instalação (debootstrap, gdisk, grub-efi-amd64, grub-pc)
- Utilitários (vim, sudo, curl, wget, git, htop)

## Troubleshooting

### Erro: "No space left on device"

Aumente o tamanho do boot pool:
```bash
sudo install-zfs --disk /dev/sdX --boot-pool-size 4G ...
```

### Erro: "Failed to import pool"

Reimple o disco e tente novamente:
```bash
sudo zpool labelclear /dev/sdX
sudo wipefs -a /dev/sdX
```

### Erro: "GRUB installation failed"

Verifique se o disco está no modo UEFI:
```bash
# Verificar modo de boot
ls /sys/firmware/efi
```

## Referências

- [OpenZFS Documentation](https://openzfs.github.io/openzfs-docs/)
- [Debian ZFS Root on ZFS Guide](https://github.com/openzfs/openzfs-docs)
- [live-build Manual](https://live-team.pages.debian.net/live-manual/)

## Licença

MIT License
