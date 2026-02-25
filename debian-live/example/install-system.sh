#!/usr/bin/env bash
#
# install-fileserver.sh - Instalador FileServer OS (Debian + ZFS-on-Root + ZFSBootMenu)
# Versão: 1.0
# Desenvolvido para FileServer OS
#

set -euo pipefail

# =============================================================================
# CONFIGURAÇÕES DE AMBIENTE AVANÇADAS
# =============================================================================

# Suporte a cores, emojis e mouse no terminal
export TERM="xterm-256color"
export COLORTERM="truecolor"
export FORCE_COLOR="1"
export CLICOLOR="1"
export CLICOLOR_FORCE="1"

# Configurar locale para suporte a UTF-8/emojis
export LANG="pt_BR.UTF-8"
export LC_ALL="pt_BR.UTF-8"
export LC_CTYPE="pt_BR.UTF-8"

# Framebuffer e suporte gráfico no console
export FRAMEBUFFER="true"
export FBTERM="true"

# Configurações do Gum para melhor renderização
export GUM_FORMAT="markdown"
export GUM_STYLE="border.rounded"
export GUM_CHOOSE="cursor.prefix=➤"

# =============================================================================
# CONFIGURAÇÕES GLOBAIS
# =============================================================================

readonly SCRIPT_NAME="FileServer OS Installer"
readonly SCRIPT_VERSION="1.0"
readonly POOL_NAME="zroot"
readonly ZBM_BIN_DIR="/usr/share/zfsbootmenu"
readonly MOUNT_POINT="/mnt/target"
readonly LOG_FILE="/var/log/fileserver-installer.log"

# Variáveis globais (serão populadas durante a execução)
declare -a SELECTED_DISKS=()
declare RAID_TOPOLOGY=""
declare ASHIFT=12
declare COMPRESSION="zstd"
declare CHECKSUM="on"
declare COPIES=1
declare HDSIZE=""
declare SQUASHFS_PATH=""
declare ENCRYPTION="off"
declare ENCRYPTION_PASSPHRASE=""
declare PROFILE="Server"

# --- Sistema de Design Aurora ---
readonly COLOR_PRIMARY="#5f5faf"   # Roxo Aurora
readonly COLOR_SECONDARY="#00afaf" # Ciano
readonly COLOR_SUCCESS="#00af00"   # Verde
readonly COLOR_ERROR="#af0000"     # Vermelho
readonly COLOR_WARNING="#ffaf00"   # Laranja
readonly COLOR_INFO="#5fafff"      # Azul Claro
readonly COLOR_BORDER="#afafff"    # Borda Suave
readonly UI_WIDTH=70

# =============================================================================
# MÓDULO: DETECÇÃO DE AMBIENTE
# =============================================================================

# Detectar capacidades do terminal e otimizar ambiente
detect_terminal_capabilities() {
	log "Detectando capacidades do terminal..."
	
	# Detectar suporte a cores
	if [[ -n "${COLORTERM:-}" ]] || [[ "${TERM:-}" == *256color* ]] || tput colors >/dev/null 2>&1; then
		export HAS_COLOR="true"
		log "✓ Suporte a cores detectado"
	else
		export HAS_COLOR="false"
		log "⚠ Terminal sem suporte a cores"
	fi
	
	# Detectar suporte a UTF-8/emojis
	if locale -k LC_CTYPE 2>/dev/null | grep -q "charmap.*UTF-8"; then
		export HAS_UTF8="true"
		log "✓ Suporte a UTF-8/emojis detectado"
	else
		export HAS_UTF8="false"
		log "⚠ Terminal sem suporte a UTF-8"
	fi
	
	# Detectar suporte a mouse
	if command -v gpm >/dev/null 2>&1 && [[ -d /dev/input/mice ]]; then
		export HAS_MOUSE="true"
		log "✓ Suporte a mouse (GPM) detectado"
	else
		export HAS_MOUSE="false"
		log "⚠ Mouse não disponível"
	fi
	
	# Detectar framebuffer
	if [[ -d /dev/fb0 ]] || [[ -n "${FRAMEBUFFER:-}" ]]; then
		export HAS_FRAMEBUFFER="true"
		log "✓ Framebuffer detectado"
	else
		export HAS_FRAMEBUFFER="false"
		log "⚠ Framebuffer não disponível"
	fi
	
	# Otimizar configurações do Gum baseado nas capacidades
	if [[ "${HAS_COLOR}" == "true" ]]; then
		export GUM_STYLE="border.rounded"
	else
		export GUM_STYLE="border.normal"
	fi
	
	if [[ "${HAS_UTF8}" == "false" ]]; then
		# Desabilitar emojis se não houver suporte UTF-8
		export NO_EMOJIS="true"
		log "⚠ Emojis desabilitados (sem UTF-8)"
	fi
}

# =============================================================================
# MÓDULO: UTILITÁRIOS DE INTERFACE
# =============================================================================

# Renderizar uma caixa estilizada
# Uso: styled_box <cor> <título> [linha_mensagem_1] [linha_mensagem_2] ...
styled_box() {
	local color="$1"
	local title="$2"
	shift 2

	clear
	gum style \
		--border rounded \
		--border-foreground "${color}" \
		--padding "1 2" \
		--margin "1 1" \
		--width "${UI_WIDTH}" \
		"$(gum style --foreground "${color}" --bold "${title}")" "" "$@"
}

# Renderizar um cabeçalho de seção
# Uso: section_header "Título da Seção"
section_header() {
	gum style \
		--foreground "${COLOR_PRIMARY}" \
		--bold \
		--margin "1 0 0 0" \
		"─── $1 ──────────────────────────────────────────────────────────" | cut -c1-"${UI_WIDTH}"
}

# =============================================================================
# MÓDULO: LOGGING
# =============================================================================

# Log de informações
# Uso: log "Mensagem de log"
log() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >>"${LOG_FILE}"
}

# Log de aviso (não crítico)
# Uso: log_warn "Mensagem de aviso"
log_warn() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARN: $*" >>"${LOG_FILE}"
}

# Log de erro e saída
# Uso: error_exit "Mensagem de erro"
error_exit() {
	styled_box "${COLOR_ERROR}" "❌ ERRO CRÍTICO" "$1"
	log "ERROR: $*"
	cleanup
	exit 1
}

# =============================================================================
# MÓDULO: CLEANUP
# =============================================================================

# Função de limpeza executada em caso de erro ou interrupção
cleanup() {
	log "Iniciando limpeza..."
	sync

	# Desmontar ESP se estiver montado
	if mountpoint -q "${MOUNT_POINT}/boot/efi"; then
		log "Desmontando ${MOUNT_POINT}/boot/efi"
		umount "${MOUNT_POINT}/boot/efi" 2>/dev/null || true
	fi

	# Desmontar sistemas virtuais se estiverem montados
	for dir in dev proc sys run; do
		if mountpoint -q "${MOUNT_POINT}/${dir}"; then
			log "Desmontando ${MOUNT_POINT}/${dir}"
			umount -l "${MOUNT_POINT}/${dir}" 2>/dev/null || true
		fi
	done

	# Desmontar root se estiver montado
	if mountpoint -q "${MOUNT_POINT}"; then
		log "Desmontando ${MOUNT_POINT}"
		umount -l "${MOUNT_POINT}" 2>/dev/null || true
	fi

	# Exportar pool ZFS se existir
	if zpool list "${POOL_NAME}" >/dev/null 2>&1; then
		log "Exportando pool ${POOL_NAME}"
		zpool export "${POOL_NAME}" 2>/dev/null || true
	fi

	log "Limpeza concluída."
}

# Configurar trap para capturar sinais
trap cleanup ERR SIGINT SIGTERM

# =============================================================================
# MÓDULO: PRÉ-REQUISITOS
# =============================================================================

# Verificar se está rodando como root
check_root() {
	if [[ ${EUID} -ne 0 ]]; then
		error_exit "Este script precisa ser executado como root."
	fi
	log "Verificação de root: OK"
}

# Carregar módulo ZFS
load_zfs_module() {
	# Verificação mais robusta usando /sys/module e /proc/modules
	if [[ ! -d /sys/module/zfs ]] || ! grep -qw "^zfs " /proc/modules; then
		log "Carregando módulo ZFS..."
		sync
		if ! modprobe zfs 2>>"${LOG_FILE}"; then
			error_exit "Falha ao carregar o módulo ZFS. Verifique se o ZFS está instalado corretamente."
		fi
		log "Módulo ZFS carregado com sucesso."
	else
		log "Módulo ZFS já está carregado."
	fi
}

# Verificar comandos ZFS
check_zfs_commands() {
	local missing_commands=()

	if ! command -v zpool >/dev/null 2>&1; then
		missing_commands+=("zpool")
	fi

	if ! command -v zfs >/dev/null 2>&1; then
		missing_commands+=("zfs")
	fi

	if [[ ${#missing_commands[@]} -gt 0 ]]; then
		error_exit "Comandos ZFS não encontrados: ${missing_commands[*]}. Pacote zfsutils-linux não instalado?"
	fi

	log "Comandos ZFS verificados: OK"
}

# Testar funcionalidade zpool
test_zpool() {
	if ! zpool version >>"${LOG_FILE}" 2>&1; then
		error_exit "Comando zpool não funcionou. Módulo ZFS pode estar corrompido."
	fi
	log "Teste zpool version: OK"
}

# Verificar memória disponível
check_memory() {
	local mem_kb mem_gb mem_mb

	mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
	mem_gb=$((mem_kb / 1024 / 1024))
	mem_mb=$((mem_kb / 1024))

	log "Memória detectada: ${mem_mb}MB (${mem_gb}GB)"

	if [[ ${mem_gb} -lt 2 ]]; then
		gum format -- "> ⚠️ Aviso: Memória baixa detectada (${mem_mb}MB). ZFS recomenda 2GB+."
		log "AVISO: Memória baixa: ${mem_mb}MB"
	fi
}

# Verificar comandos necessários
check_required_commands() {
	local commands=("gum" "wipefs" "sgdisk" "mkfs.vfat" "efibootmgr" "unsquashfs" "rsync" "syslinux" "dd")
	local missing=()

	for cmd in "${commands[@]}"; do
		if ! command -v "${cmd}" >/dev/null 2>&1; then
			missing+=("${cmd}")
		fi
	done

	if [[ ${#missing[@]} -gt 0 ]]; then
		error_exit "Comandos necessários não encontrados: ${missing[*]}"
	fi

	# Verificar se arquivos do syslinux existem (gptmbr.bin é crucial)
	if [[ ! -f /usr/lib/syslinux/mbr/gptmbr.bin ]]; then
		missing+=("syslinux-common (gptmbr.bin)")
	fi

	if [[ ${#missing[@]} -gt 0 ]]; then
		error_exit "Dependências do Syslinux não encontradas: ${missing[*]}"
	fi

	log "Comandos necessários verificados: OK"
}

# Executar todas as verificações de pré-requisitos
preflight_checks() {
	log "Executando verificações de pré-requisitos..."

	check_root
	detect_terminal_capabilities
	load_zfs_module
	check_zfs_commands
	test_zpool
	check_memory
	check_required_commands

	log "Verificações de pré-requisitos concluídas."
	sync
}

# =============================================================================
# MÓDULO: INTERFACE TUI
# =============================================================================

welcome_screen() {
	styled_box "${COLOR_PRIMARY}" "🌌 FILESERVER OS" \
		"Bem-vindo ao instalador oficial do **FileServer OS**." \
		"" \
		"Este assistente irá guiá-lo através da instalação do Debian com" \
		"**ZFS-on-Root** e **ZFSBootMenu**." \
		"" \
		"> *Aviso: Este processo é destrutivo para os discos selecionados.*"
	gum confirm "Deseja iniciar a jornada de instalação?" || exit 0
}

select_disks() {
	local disks
	section_header "Seleção de Discos"

	# Verificar se há discos disponíveis antes de prosseguir
	disks=$(lsblk -d -n -o NAME,SIZE,MODEL -e 7,11 | awk '{printf "/dev/%s (%s - %s)\n", $1, $2, substr($0, index($0,$3))}')

	if [[ -z "${disks}" ]]; then
		error_exit "Nenhum disco adequado para instalação foi encontrado pelo lsblk."
	fi

	local raw_selection
	# Capturar seleção com indicadores visuais claros de checkbox (X em verde)
	if ! raw_selection=$(echo -n "${disks}" | gum choose \
		--header "Selecione o(s) disco(s) (ESPAÇO para marcar, ENTER para confirmar):" \
		--no-limit \
		--cursor="> " \
		--selected-prefix="[$(gum style --foreground "${COLOR_SUCCESS}" "X")] " \
		--unselected-prefix="[ ] " \
		--cursor-prefix="[ ] " \
		--selected.foreground=""); then
		error_exit "Seleção de discos cancelada pelo usuário."
	fi

	log "Seleção bruta do gum (raw_selection):
${raw_selection}"

	if [[ -z "${raw_selection}" ]]; then
		error_exit "Nenhum disco selecionado."
	fi

	SELECTED_DISKS=()
	# Processar cada linha selecionada
	while IFS= read -r sel; do
		[[ -z "${sel}" ]] && continue
		log "Processando linha de seleção: '${sel}'"

		local dev
		# Extrair o caminho do dispositivo de forma robusta (/dev/sdX, /dev/nvmeXnX, /dev/mmcblkX, etc)
		dev=$(echo "${sel}" | grep -oE '/dev/[a-z0-9/]+' | head -n 1)

		if [[ -n "${dev}" ]] && [[ -b "${dev}" ]]; then
			SELECTED_DISKS+=("${dev}")
			gum format -- "✓ Selecionado: **${dev}**"
			log "Dispositivo extraído com sucesso: ${dev}"
		else
			log "AVISO: Falha ao extrair dispositivo válido da linha: '${sel}' (extraído: '${dev}')"
		fi
	done <<<"${raw_selection}"

	if [[ ${#SELECTED_DISKS[@]} -eq 0 ]]; then
		error_exit "Não foi possível identificar dispositivos válidos na sua seleção."
	fi

	styled_box "${COLOR_WARNING}" "⚠️ ALERTA DE SEGURANÇA" \
		"TODOS OS DADOS nos discos selecionados serão APAGADOS permanentEMENTE." \
		"" \
		"Discos: **${SELECTED_DISKS[*]}**"
	gum confirm "Tem certeza absoluta que deseja prosseguir?" || exit 0

	log "Discos selecionados: ${SELECTED_DISKS[*]}"
}

collect_info() {
	section_header "Identidade do Sistema"
	HOSTNAME=$(gum input --prompt " 🏷️  Hostname: " --placeholder "Ex: fileserver" --value "fileserver")
	USERNAME=$(gum input --prompt " 👤 Usuário:  " --placeholder "Ex: admin" --value "admin")

	section_header "Configurações de Segurança"
	USER_PASS=$(gum input --prompt " 🔑 Senha (${USERNAME}): " --password --placeholder "Digite a senha do usuário")
	ROOT_PASS=$(gum input --prompt " 🛡️  Senha (root):     " --password --placeholder "Digite a senha do root")

	if [[ -z "${USER_PASS}" || -z "${ROOT_PASS}" ]]; then
		error_exit "As senhas não podem ser vazias."
	fi

	# Validar comprimento mínimo da senha
	if [[ ${#USER_PASS} -lt 6 ]]; then
		error_exit "A senha do usuário deve ter pelo menos 6 caracteres."
	fi
	if [[ ${#ROOT_PASS} -lt 6 ]]; then
		error_exit "A senha do root deve ter pelo menos 6 caracteres."
	fi

	log "Coletadas informações: hostname=${HOSTNAME}, username=${USERNAME}"
}

confirm_installation() {
	local disk_list
	disk_list=$(
		IFS=$'\n'
		echo "${SELECTED_DISKS[*]}"
	)

	local summary_text
	summary_text="
$(gum style --foreground "${COLOR_SECONDARY}" --bold "🌍 GERAL")
• Discos:     ${SELECTED_DISKS[*]}
• Topologia:  ${RAID_TOPOLOGY}
• Hostname:   ${HOSTNAME}
• Usuário:    ${USERNAME}
• Perfil:     ${PROFILE}

$(gum style --foreground "${COLOR_SECONDARY}" --bold "⚡ ZFS")
• Pool:       ${POOL_NAME}
• ashift:     ${ASHIFT}
• compress:   ${COMPRESSION}
• checksum:   ${CHECKSUM}
• copies:     ${COPIES}
• Crypto:     ${ENCRYPTION}
"

	styled_box "${COLOR_INFO}" "📋 RESUMO DA INSTALAÇÃO" "${summary_text}"
	gum confirm "As configurações estão corretas? Iniciar instalação?" || exit 0
}

# Selecionar topologia RAID
select_topology() {
	local num_disks=${#SELECTED_DISKS[@]}
	local options=()

	case ${num_disks} in
	1)
		options=("Single")
		;;
	2)
		options=("Mirror" "Stripe")
		;;
	3)
		options=("Mirror" "RAIDZ1" "Stripe")
		;;
	4)
		options=("Mirror" "RAIDZ1" "RAIDZ2" "Stripe")
		;;
	*)
		options=("Mirror" "RAIDZ1" "RAIDZ2" "RAIDZ3" "Stripe")
		;;
	esac

	RAID_TOPOLOGY=$(echo "${options[@]}" | tr ' ' '\n' | gum choose --header "Selecione a topologia RAID:")
	log "Topologia selecionada: ${RAID_TOPOLOGY}"
}

# Configurar opções ZFS avançadas
configure_zfs_options() {
	section_header "Configuração ZFS Avançada"

	ASHIFT=$(gum choose --header "Selecione ashift (tamanho do setor):" \
		"9" "12" "13" "14" \
		--selected "12" || echo "12")

	COMPRESSION=$(gum choose --header "Selecione compressão:" \
		"off" "lz4" "zstd" "gzip" \
		--selected "zstd" || echo "zstd")

	CHECKSUM=$(gum choose --header "Selecione checksum:" \
		"on" "off" "sha256" "sha512" \
		--selected "on" || echo "on")

	COPIES=$(gum choose --header "Selecione cópias (redundância):" \
		"1" "2" "3" \
		--selected "1" || echo "1")

	HDSIZE=$(gum input --prompt "Limite de tamanho do disco em GB (opcional, pressione Enter para ignorar):" --placeholder "" || echo "")

	if [[ -n "${HDSIZE}" ]]; then
		# Validar que HDSIZE é um número
		if ! [[ "${HDSIZE}" =~ ^[0-9]+$ ]]; then
			error_exit "HDSIZE deve ser um número inteiro positivo."
		fi

		gum format -- "> Será usado apenas os primeiros ${HDSIZE}GB de cada disco"
	fi


	# Configuração de Criptografia
	ENCRYPTION=$(gum choose --header "Deseja habilitar criptografia nativa ZFS?" \
		"off" "on" \
		--selected "off" || echo "off")

	if [[ "${ENCRYPTION}" == "on" ]]; then
		ENCRYPTION_PASSPHRASE=$(gum input --password --prompt "Digite a passphrase do pool ZFS:" --placeholder "Passphrase")
		local confirm_pass
		confirm_pass=$(gum input --password --prompt "Confirme a passphrase:" --placeholder "Passphrase")

		if [[ "${ENCRYPTION_PASSPHRASE}" != "${confirm_pass}" ]]; then
			error_exit "As passphrases não coincidem."
		fi

		if [[ ${#ENCRYPTION_PASSPHRASE} -lt 8 ]]; then
			error_exit "A passphrase de criptografia deve ter pelo menos 8 caracteres."
		fi
	fi

	log "Opções ZFS: ashift=${ASHIFT}, compression=${COMPRESSION}, checksum=${CHECKSUM}, copies=${COPIES}${HDSIZE:+, hdsize=${HDSIZE}}, encryption=${ENCRYPTION}, profile=${PROFILE}"
}

# =============================================================================
# MÓDULO: PREPARAÇÃO DO DISCO
# =============================================================================

# Limpar completamente um disco
wipe_disk() {
	local disk=$1

	log "Limpando disco ${disk}..."

	if ! wipefs -a "${disk}" >>"${LOG_FILE}" 2>&1; then
		error_exit "Falha ao executar wipefs em ${disk}"
	fi

	if ! sgdisk --zap-all "${disk}" >>"${LOG_FILE}" 2>&1; then
		error_exit "Falha ao executar sgdisk --zap-all em ${disk}"
	fi

	sync
	log "Disco ${disk} limpo com sucesso"
}

# Determinar sufixo de partição (para /dev/sdX vs /dev/nvme0n1)
get_part_suffix() {
	local disk=$1

	if [[ ${disk} =~ /dev/nvme ]]; then
		echo "p"
	else
		echo ""
	fi
}

# Particionar um disco específico
partition_disk() {
	local disk=$1
	local part_suffix
	part_suffix=$(get_part_suffix "${disk}")

	log "Particionando disco ${disk}..."

	# Estrutura para Syslinux (BIOS) + ZBM (UEFI):
	# 1. ESP (EFI System Partition) - FAT32 - 512MB
	#    - Carrega ZBM via UEFI (direto)
	#    - Carrega Syslinux via BIOS (ponte)
	#    - Deve ter atributo Legacy Boot (bit 2) para Syslinux funcionar
	# 2. ZFS Root - ZFS - Restante

	sgdisk -n 1:2048:+512M -t 1:EF00 -c 1:'EFI System' "${disk}" >>"${LOG_FILE}" 2>&1 || error_exit "Falha ao criar partição EFI em ${disk}"
	
	# Habilitar Legacy Boot na ESP (BIOS bootable)
	sgdisk -A 1:set:2 "${disk}" >>"${LOG_FILE}" 2>&1 || error_exit "Falha ao definir atributo Legacy Boot na ESP"

	if [[ -n "${HDSIZE}" ]]; then
		local hdsize_bytes=$((HDSIZE * 1024 * 1024 * 1024 / 512))
		sgdisk -n 2:0:+${hdsize_bytes} -t 2:BF00 -c 2:'ZFS Root' "${disk}" >>"${LOG_FILE}" 2>&1 || error_exit "Falha ao criar partição ZFS em ${disk} com hdsize"
	else
		sgdisk -n 2:0:0 -t 2:BF00 -c 2:'ZFS Root' "${disk}" >>"${LOG_FILE}" 2>&1 || error_exit "Falha ao criar partição ZFS em ${disk}"
	fi

	partprobe "${disk}" >>"${LOG_FILE}" 2>&1 || error_exit "Falha ao executar partprobe em ${disk}"
	sync
	log "Particionamento de ${disk} concluído"
}

# Selecionar perfil de instalação
select_profile() {
	section_header "Seleção de Perfil"

	local selected
	selected=$(gum choose \
		--header "Selecione o perfil de instalação:" \
		"Server" \
		"Workstation" \
		--selected "Server")

	if [[ -z "${selected}" ]]; then
		PROFILE="Server"
	else
		PROFILE="${selected}"
	fi
	
	log "Perfil selecionado: ${PROFILE}"
	gum format -- "✓ Perfil selecionado: ${PROFILE}"
}

# Preparar todos os discos selecionados
prepare_disks() {
	gum format -- "### Preparando Discos"

	for disk in "${SELECTED_DISKS[@]}"; do
		local disk_title
		if [[ -n "${HDSIZE}" ]]; then
			disk_title="${disk} (${HDSIZE}GB)"
		else
			disk_title="${disk}"
		fi

		# Construir comando de particionamento baseado em HDSIZE
		local partition_cmd
		if [[ -n "${HDSIZE}" ]]; then
			local hdsize_bytes=$((HDSIZE * 1024 * 1024 * 1024 / 512))
			partition_cmd="
				wipefs -a '${disk}'
				sgdisk --zap-all '${disk}'
				sgdisk -n 1:2048:+512M -t 1:EF00 -c 1:'EFI System' '${disk}'
				sgdisk -A 1:set:2 '${disk}'
				sgdisk -n 2:0:+${hdsize_bytes} -t 2:BF00 -c 2:'ZFS Root' '${disk}'
				partprobe '${disk}'
				sleep 2
			"
		else
			partition_cmd="
				wipefs -a '${disk}'
				sgdisk --zap-all '${disk}'
				sgdisk -n 1:2048:+512M -t 1:EF00 -c 1:'EFI System' '${disk}'
				sgdisk -A 1:set:2 '${disk}'
				sgdisk -n 2:0:0 -t 2:BF00 -c 2:'ZFS Root' '${disk}'
				partprobe '${disk}'
				sleep 2
			"
		fi

		gum spin --spinner dot --title "Limpando e particionando ${disk_title}..." -- bash -c "${partition_cmd}" || error_exit "Falha ao preparar disco ${disk}"
		log "Disco ${disk} preparado com sucesso"
	done

	# Atualizar symlinks de dispositivos após particionamento
	udevadm trigger
	udevadm settle

	gum format -- "✓ Todos os discos preparados com sucesso!"
	log "Preparação de discos concluída"
}

# =============================================================================
# MÓDULO: CONFIGURAÇÃO ZFS
# =============================================================================

# Coletar partições ZFS de todos os discos
get_zfs_partitions() {
	local -a zfs_parts=()

	log "Gerando lista de partições para discos: ${SELECTED_DISKS[*]}"
	for disk in "${SELECTED_DISKS[@]}"; do
		[[ -z "${disk}" ]] && continue
		local part_suffix
		part_suffix=$(get_part_suffix "${disk}")
		# Partição 2 agora é ZFS Root (antes era 3)
		log "Disco: ${disk}, Sufixo: ${part_suffix}, Partição: ${disk}${part_suffix}2"
		zfs_parts+=("${disk}${part_suffix}2")
	done

	for part in "${zfs_parts[@]}"; do
		echo "${part}"
	done
}


# Criar pool ZFS com topologia e opções selecionadas
create_pool() {
	local -a zfs_parts=()
	mapfile -t zfs_parts < <(get_zfs_partitions)

	if [[ ${#zfs_parts[@]} -eq 0 ]]; then
		error_exit "Nenhuma partição ZFS encontrada. Verifique se os discos foram particionados corretamente."
	fi

	log "Partições ZFS detectadas: ${zfs_parts[*]}"

	# Verificar se já existe pool com esse nome e forçar exportação
	if zpool list "${POOL_NAME}" >/dev/null 2>&1; then
		log "Pool ${POOL_NAME} já existe, iniciando procedimento de limpeza..."
		gum format -- "> Pool ${POOL_NAME} existente detectado, limpando..."

		# 1. Sincronizar todos os buffers
		sync

		# 2. Desabilitar swap se estiver em ZFS
		swapoff -a 2>>"${LOG_FILE}" || true

		# 3. Desmontagem recursiva do mountpoint com lazy unmount
		if [[ -d "${MOUNT_POINT}" ]]; then
			log "Desmontando recursivamente ${MOUNT_POINT} (lazy)..."
			umount -Rl "${MOUNT_POINT}" 2>>"${LOG_FILE}" || true
			sleep 1
		fi

		# 4. Desmontar todos os datasets do pool (lazy)
		for ds in $(zfs list -H -o name -r "${POOL_NAME}" 2>/dev/null | tac); do
			log "Desmontando dataset: ${ds}"
			zfs unmount -f "${ds}" 2>>"${LOG_FILE}" || true
		done

		# 5. Identificar e logar processos usando o pool (apenas informativo)
		if command -v lsof >/dev/null 2>&1; then
			local busy_procs
			busy_procs=$(lsof +D "${MOUNT_POINT}" 2>/dev/null || true)
			if [[ -n "${busy_procs}" ]]; then
				log "Processos ainda usando ${MOUNT_POINT}:"
				log "${busy_procs}"
			fi
		fi

		# 6. Tentar exportar com força
		log "Tentando exportar pool ${POOL_NAME}..."
		sync
		sleep 1
		if ! zpool export -f "${POOL_NAME}" 2>>"${LOG_FILE}"; then
			log "Primeira tentativa de export falhou, aguardando e tentando novamente..."
			sleep 2
			sync
			zpool export -f "${POOL_NAME}" 2>>"${LOG_FILE}" || true
		fi

		# 7. Se ainda existir, destruir forçadamente
		if zpool list "${POOL_NAME}" >/dev/null 2>&1; then
			log "Pool ainda existe após export, tentando destruir..."
			zpool destroy -f "${POOL_NAME}" 2>>"${LOG_FILE}" || {
				log "ERRO CRÍTICO: Não foi possível remover o pool existente."
				log "O pool pode estar sendo usado por outro processo."
				log "Tente reiniciar o sistema live e executar novamente."
				error_exit "Falha ao remover pool existente. Reinicie o sistema live."
			}
		fi

		log "Pool antigo removido com sucesso."
	fi

	# Limpar labels ZFS existentes nas partições
	for part in "${zfs_parts[@]}"; do
		zpool labelclear -f "${part}" 2>>"${LOG_FILE}" || true
	done

	gum format -- "### Criando Pool ZFS (${RAID_TOPOLOGY})"

	local pool_cmd=(
		zpool create -f
		-o "ashift=${ASHIFT}"
		-o autotrim=on
		-O acltype=posixacl
		-O canmount=off
		-O "compression=${COMPRESSION}"
		-O dnodesize=auto
		-O normalization=formD
		-O relatime=on
		-O xattr=sa
		-O mountpoint=none
		-O "checksum=${CHECKSUM}"
		-O "copies=${COPIES}"
		-R "${MOUNT_POINT}"
	)

	# Construir argumentos de topologia
	local -a topology_args=()
	case ${RAID_TOPOLOGY} in
	Single)
		topology_args+=("${POOL_NAME}" "${zfs_parts[0]}")
		;;
	Stripe)
		topology_args+=("${POOL_NAME}" "${zfs_parts[@]}")
		;;
	Mirror)
		topology_args+=("${POOL_NAME}" mirror "${zfs_parts[@]}")
		;;
	RAIDZ1)
		topology_args+=("${POOL_NAME}" raidz1 "${zfs_parts[@]}")
		;;
	RAIDZ2)
		topology_args+=("${POOL_NAME}" raidz2 "${zfs_parts[@]}")
		;;
	RAIDZ3)
		topology_args+=("${POOL_NAME}" raidz3 "${zfs_parts[@]}")
		;;
	esac

	# Adicionar opções de criptografia se habilitado
	if [[ "${ENCRYPTION}" == "on" ]]; then
		log "Habilitando criptografia nativa no pool..."
		pool_cmd+=(
			-O encryption=aes-256-gcm
			-O keyformat=passphrase
			-O keylocation=prompt
		)

		# Executar com pipe para a senha
		log "Executando zpool create com criptografia: ${pool_cmd[*]} ${topology_args[*]}"
		sync
		if ! echo "${ENCRYPTION_PASSPHRASE}" | "${pool_cmd[@]}" "${topology_args[@]}" 2>>"${LOG_FILE}"; then
			error_exit "Falha ao criar pool ZFS criptografado. Verifique ${LOG_FILE}."
		fi
	else
		log "Executando zpool create: ${pool_cmd[*]} ${topology_args[*]}"
		sync
		if ! "${pool_cmd[@]}" "${topology_args[@]}" 2>>"${LOG_FILE}"; then
			error_exit "Falha ao criar pool ZFS. Verifique ${LOG_FILE}."
		fi
	fi

	# Configurar cachefile para garantir importação correta no boot
	zpool set cachefile=/etc/zfs/zpool.cache "${POOL_NAME}" 2>>${LOG_FILE} || true

	log "Pool ZFS '${POOL_NAME}' criado com sucesso em ${RAID_TOPOLOGY}"
	gum format -- "✓ Pool ZFS criado: ${POOL_NAME} (${RAID_TOPOLOGY})"
}

# Criar hierarquia de datasets ZFS
create_datasets() {
	gum format -- "### Criando Datasets ZFS"

	log "Criando dataset ROOT..."
	zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/ROOT" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao criar dataset ROOT"

	log "Criando dataset ROOT/debian..."
	zfs create -o canmount=noauto -o mountpoint=/ -o com.sun:auto-snapshot=true "${POOL_NAME}/ROOT/debian" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao criar dataset ROOT/debian"

	zfs mount "${POOL_NAME}/ROOT/debian" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao montar dataset ROOT/debian"

	log "Criando dataset home..."
	zfs create -o mountpoint=/home -o com.sun:auto-snapshot=true "${POOL_NAME}/home" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao criar dataset home"

	log "Criando dataset home/root..."
	zfs create -o mountpoint=/root "${POOL_NAME}/home/root" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao criar dataset home/root"

	log "Criando dataset var..."
	zfs create -o mountpoint=/var -o canmount=off "${POOL_NAME}/var" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao criar dataset var"

	log "Criando dataset var/log..."
	zfs create -o com.sun:auto-snapshot=true "${POOL_NAME}/var/log" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao criar dataset var/log"

	log "Criando dataset var/cache..."
	zfs create -o com.sun:auto-snapshot=false "${POOL_NAME}/var/cache" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao criar dataset var/cache"

	log "Criando dataset var/tmp..."
	zfs create -o com.sun:auto-snapshot=false "${POOL_NAME}/var/tmp" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao criar dataset var/tmp"

	log "Configurando propriedade de linha de comando para ZFSBootMenu..."
	zfs set org.zfsbootmenu:commandline="quiet" "${POOL_NAME}/ROOT/debian" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao configurar commandline do ZFSBootMenu"

	# Definir bootfs conforme documentação oficial - indica o BE padrão para boot
	log "Definindo bootfs padrão..."
	zpool set bootfs="${POOL_NAME}/ROOT/debian" "${POOL_NAME}" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao definir bootfs"

	gum format -- "✓ Datasets ZFS criados com sucesso!"
	log "Todos os datasets ZFS criados com sucesso"
	sync
}

# =============================================================================
# MÓDULO: EXTRAÇÃO DO SISTEMA
# =============================================================================

# Validar existência do arquivo squashfs
validate_squashfs() {
	local squashfs_paths=(
		"/run/live/medium/live/00-core.squashfs"
		"/lib/live/mount/medium/live/00-core.squashfs"
		"/cdrom/live/00-core.squashfs"
		"/run/live/medium/live/filesystem.squashfs"
	)
	local found_path=""

	log "Buscando arquivo squashfs..."
	for path in "${squashfs_paths[@]}"; do
		if [[ -f "${path}" ]]; then
			found_path="${path}"
			log "Squashfs encontrado em: ${found_path}"
			break
		fi
	done

	if [[ -z "${found_path}" ]]; then
		gum format -- "
## ❌ Arquivo Squashfs Não Encontrado

O instalador não conseguiu encontrar o arquivo \`00-core.squashfs\` (ou filesystem.squashfs).
Este arquivo é necessário para extrair o sistema base.

**Caminhos verificados:**
\`\`\`
${squashfs_paths[*]}
\`\`\`

**Possíveis causas:**
- ISO foi corrompida durante o download
- Boot não foi feito corretamente
- Diretório /live não foi montado

**Solução:**
1. Verifique o hash da ISO
2. Recrie a ISO usando os scripts de build
3. Tente novamente a instalação
		"
		error_exit "Arquivo squashfs não encontrado em nenhum dos caminhos esperados."
	fi

	# Exportar caminho encontrado para uso em outras funções
	export SQUASHFS_PATH="${found_path}"
	gum format -- "✓ Arquivo squashfs encontrado: ${SQUASHFS_PATH}"

	# Listar todos os layers disponíveis para diagnóstico
	local squash_dir
	squash_dir=$(dirname "${SQUASHFS_PATH}")
	log "Diretório de layers: ${squash_dir}"
	log "Layers disponíveis:"
	
	local layers_info=""
	for layer in "${squash_dir}"/*.squashfs; do
		if [[ -f "${layer}" ]]; then
			local layer_name layer_size
			layer_name=$(basename "${layer}")
			layer_size=$(ls -lh "${layer}" | awk '{print $5}')
			log "  - ${layer_name} (${layer_size})"
			layers_info="
			${layers_info}
			  • ${layer_name} (${layer_size})
			"
		fi
	done
	
	gum format -- "
### Layers Disponíveis
${layers_info}
"
}


# Criar diretórios essenciais no sistema de destino
create_essential_dirs() {
	log "Criando diretórios essenciais..."

	mkdir -p "${MOUNT_POINT}" || error_exit "Falha ao criar diretório ${MOUNT_POINT}"
	mkdir -p "${MOUNT_POINT}/dev" || error_exit "Falha ao criar ${MOUNT_POINT}/dev"
	mkdir -p "${MOUNT_POINT}/proc" || error_exit "Falha ao criar ${MOUNT_POINT}/proc"
	mkdir -p "${MOUNT_POINT}/sys" || error_exit "Falha ao criar ${MOUNT_POINT}/sys"
	mkdir -p "${MOUNT_POINT}/run" || error_exit "Falha ao criar ${MOUNT_POINT}/run"
	mkdir -p "${MOUNT_POINT}/tmp" || error_exit "Falha ao criar ${MOUNT_POINT}/tmp"

	chmod 1777 "${MOUNT_POINT}/tmp" || error_exit "Falha ao definir permissões em ${MOUNT_POINT}/tmp"

	log "Diretórios essenciais criados com sucesso"
	gum format -- "✓ Diretórios essenciais criados"
}

# Extrair sistema do arquivo squashfs
extract_system() {
	log "Iniciando extração do sistema de ${SQUASHFS_PATH}..."

	# Verificar novamente se o arquivo existe (segurança)
	if [[ ! -f "${SQUASHFS_PATH}" ]]; then
		error_exit "Arquivo squashfs desapareceu: ${SQUASHFS_PATH}"
	fi

	gum format -- "### Extraindo Sistema"

	# unsquashfs precisa de stdin redirecionado de /dev/null para evitar
	# "inappropriate ioctl for device" quando executado via gum spin
	local squash_dir
	squash_dir=$(dirname "${SQUASHFS_PATH}")
	
	# Função auxiliar para extrair um squashfs
	extract_layer() {
		local layer_file="$1"
		local layer_name="$2"
		
		if [[ ! -f "${layer_file}" ]]; then
			log_warn "Camada ${layer_name} não encontrada em ${layer_file}, pulando."
			return 0
		fi
		
		log "Extraindo camada: ${layer_name}..."
		local log_tmp
		log_tmp=$(mktemp)
		
		if ! gum spin --spinner dot --title "Extraindo camada ${layer_name}..." -- \
			bash -c "unsquashfs -f -n -d '${MOUNT_POINT}' '${layer_file}' </dev/null >'${log_tmp}' 2>&1"; then
			cat "${log_tmp}" >>"${LOG_FILE}"
			rm -f "${log_tmp}"
			error_exit "Falha ao extrair ${layer_name}."
		fi
		cat "${log_tmp}" >>"${LOG_FILE}"
		rm -f "${log_tmp}"
	}

	# 1. Extrair Base (Core)
	# SQUASHFS_PATH já aponta para 00-core via validate_squashfs (ou filesystem.squashfs)
	extract_layer "${SQUASHFS_PATH}" "Core System"

	# 2. Extrair Camadas Adicionais baseadas no Perfil
	if [[ "${PROFILE}" == "Server" ]]; then
		extract_layer "${squash_dir}/10-server.squashfs" "Server Profile"
	elif [[ "${PROFILE}" == "Workstation" ]]; then
		# Workstation geralmente inclui Server layer + GUI, ou é independente?
		# No nosso design: Workstation é "Workstation Base". Se precisar de server utils, deve instalar ambos?
		# Assumindo camadas exclusivas por enquanto ou cumulativas se desejado.
		# A lista 20-workstation parece adicionar GUI. Vamos extrair Server TAMBÉM?
		# No package lists: 10-server (admin tools), 20-workstation (gui).
		# Geralmente workstation precisa de admin tools também.
		# Vamos extrair 10-server SE desejado, ou assumir que workstation é superset.
		# Olhando as listas, 20-workstation tem "Workstation Base".
		# Vamos extrair AMBOS para Workstation se a ideia for aditiva.
		# Se for excludente, apenas 20.
		# Decisão: Extrair 10-server para Workstation também garante ferramentas de admin.
		extract_layer "${squash_dir}/10-server.squashfs" "Server Profile (Base Tools)"
		extract_layer "${squash_dir}/20-workstation.squashfs" "Workstation Profile (GUI)"
	fi

	log "Sistema extraído com sucesso em ${MOUNT_POINT}"

	# Verificar se a extração foi bem-sucedida checando arquivos críticos
	local critical_files=("${MOUNT_POINT}/bin/bash" "${MOUNT_POINT}/etc/passwd" "${MOUNT_POINT}/usr/bin")
	local missing_files=()

	for file in "${critical_files[@]}"; do
		if [[ ! -e "${file}" ]]; then
			missing_files+=("${file}")
		fi
	done

	if [[ ${#missing_files[@]} -gt 0 ]]; then
		gum format -- "
## ⚠️ Aviso: Arquivos Críticos Ausentes

Após a extração, alguns arquivos críticos não foram encontrados:
\`\`\`
${missing_files[*]}
\`\`\`

A extração pode ter falhado parcialmente.
		"
		error_exit "Extração incompleta: ${missing_files[*]} não encontrados."
	fi

	gum format -- "✓ Sistema extraído com sucesso!"

	# Copiar zpool.cache para o sistema instalado (ajuda na importação no boot)
	mkdir -p "${MOUNT_POINT}/etc/zfs"
	cp /etc/zfs/zpool.cache "${MOUNT_POINT}/etc/zfs/" 2>>${LOG_FILE} || true
	log "zpool.cache copiado para ${MOUNT_POINT}/etc/zfs/"
}

# =============================================================================
# MÓDULO: CONFIGURAÇÃO CHROOT
# =============================================================================

# Montar sistemas de arquivos virtuais para chroot
mount_chroot_filesystems() {
	log "Montando sistemas de arquivos virtuais..."

	if ! mount --make-private --rbind /dev "${MOUNT_POINT}/dev" 2>>"${LOG_FILE}"; then
		error_exit "Falha ao montar /dev"
	fi

	if ! mount --make-private --rbind /proc "${MOUNT_POINT}/proc" 2>>"${LOG_FILE}"; then
		error_exit "Falha ao montar /proc"
	fi

	if ! mount --make-private --rbind /sys "${MOUNT_POINT}/sys" 2>>"${LOG_FILE}"; then
		error_exit "Falha ao montar /sys"
	fi

	if ! mount --make-private --rbind /run "${MOUNT_POINT}/run" 2>>"${LOG_FILE}"; then
		error_exit "Falha ao montar /run"
	fi

	log "Sistemas de arquivos virtuais montados com sucesso"
	gum format -- "✓ Sistemas de arquivos montados"
}

# Configurar hostname e /etc/hosts
configure_hostname() {
	log "Configurando hostname: ${HOSTNAME}"

	if ! echo "${HOSTNAME}" >"${MOUNT_POINT}/etc/hostname" 2>>"${LOG_FILE}"; then
		error_exit "Falha ao configurar /etc/hostname"
	fi

	if ! cat >"${MOUNT_POINT}/etc/hosts" <<HOSTSEOF; then
127.0.0.1	localhost
127.0.1.1	${HOSTNAME}
::1		localhost ip6-localhost ip6-loopback
ff02::1	ip6-allnodes
ff02::2	ip6-allrouters
HOSTSEOF
		error_exit "Falha ao configurar /etc/hosts"
	fi

	log "Hostname configurado com sucesso"
	gum format -- "✓ Hostname configurado: ${HOSTNAME}"
}

# Configurar usuários e senhas
configure_users() {
	log "Configurando usuários..."

	chroot "${MOUNT_POINT}" /bin/bash -c "echo 'root:${ROOT_PASS}' | chpasswd" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao definir senha do root"

	chroot "${MOUNT_POINT}" /bin/bash -c "useradd -m -s /bin/bash -G sudo,dip,plugdev,cdrom '${USERNAME}'" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao criar usuário ${USERNAME}"

	chroot "${MOUNT_POINT}" /bin/bash -c "echo '${USERNAME}:${USER_PASS}' | chpasswd" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao definir senha do usuário ${USERNAME}"

	log "Usuários configurados com sucesso"
	gum format -- "✓ Usuários configurados"
}

# Configurar locale e timezone
configure_locales() {
	log "Configurando locale e timezone..."

	# Permitir seleção de locale
	local selected_locale
	selected_locale=$(gum choose --header "Selecione o locale:" \
		"pt_BR.UTF-8" \
		"en_US.UTF-8" \
		--selected "pt_BR.UTF-8")

	if [[ -z "${selected_locale}" ]]; then
		selected_locale="pt_BR.UTF-8"
	fi

	if ! echo "${selected_locale} UTF-8" >"${MOUNT_POINT}/etc/locale.gen" 2>>"${LOG_FILE}"; then
		error_exit "Falha ao configurar /etc/locale.gen"
	fi

	chroot "${MOUNT_POINT}" locale-gen 2>>"${LOG_FILE}" ||
		error_exit "Falha ao executar locale-gen"

	# Extrair código de linguagem (pt_BR, en_US, etc)
	local lang_code
	lang_code=$(echo "${selected_locale}" | cut -d. -f1)

	chroot "${MOUNT_POINT}" /bin/bash -c "update-locale LANG=${selected_locale} LANGUAGE=${lang_code}" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao executar update-locale"

	# Selecionar timezone
	local selected_timezone
	selected_timezone=$(gum input --prompt "Timezone:" --value "America/Sao_Paulo" --placeholder "America/Sao_Paulo")

	if [[ -n "${selected_timezone}" ]]; then
		if ! echo "${selected_timezone}" >"${MOUNT_POINT}/etc/timezone" 2>>"${LOG_FILE}"; then
			error_exit "Falha ao configurar /etc/timezone"
		fi

		chroot "${MOUNT_POINT}" dpkg-reconfigure -f noninteractive tzdata 2>>"${LOG_FILE}" ||
			error_exit "Falha ao reconfigurar tzdata"
	fi

	log "Locale e timezone configurados com sucesso"
	gum format -- "✓ Locale e timezone configurados"
}

# Configurar /etc/fstab
configure_fstab() {
	log "Configurando /etc/fstab..."

	if ! cat >"${MOUNT_POINT}/etc/fstab" <<FSTABEOF; then
# /etc/fstab: arquivo de configuração de sistemas de arquivos estáticos
#
# Use 'blkid' para imprimir o UUID de dispositivos
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
${POOL_NAME}/ROOT/debian	/	zfs	defaults,noatime,xattr=sa	0	0
${POOL_NAME}/home		/home	zfs	defaults,noatime,xattr=sa	0	0
${POOL_NAME}/home/root	/root	zfs	defaults,noatime,xattr=sa	0	0
${POOL_NAME}/var/log	/var/log	zfs	defaults,noatime,xattr=sa	0	0
${POOL_NAME}/var/cache	/var/cache	zfs	defaults,noatime,xattr=sa	0	0
${POOL_NAME}/var/tmp	/var/tmp	zfs	defaults,noatime,xattr=sa	0	0
tmpfs		/tmp		tmpfs	defaults,nosuid,nodev,noexec,mode=1777	0	0
FSTABEOF
		error_exit "Falha ao configurar /etc/fstab"
	fi

	log "/etc/fstab configurado com sucesso"
	gum format -- "✓ /etc/fstab configurado"
}
# Gerar /etc/hostid consistente com o pool
generate_hostid() {
	log "Gerando hostid..."

	# Remover hostid existente (pode vir do squashfs) antes de gerar novo
	if [[ -f "${MOUNT_POINT}/etc/hostid" ]]; then
		log "Removendo /etc/hostid existente..."
		rm -f "${MOUNT_POINT}/etc/hostid"
	fi

	chroot "${MOUNT_POINT}" zgenhostid 2>>"${LOG_FILE}" ||
		error_exit "Falha ao gerar hostid com zgenhostid"

	log "Hostid gerado"
	gum format -- "✓ Hostid gerado"
}

# Regenerar initramfs com suporte ZFS
update_initramfs() {
	log "Habilitando serviços systemd ZFS..."

	# Habilitar serviços ZFS conforme documentação oficial
	chroot "${MOUNT_POINT}" systemctl enable zfs.target 2>>"${LOG_FILE}" || true
	chroot "${MOUNT_POINT}" systemctl enable zfs-import-cache 2>>"${LOG_FILE}" || true
	chroot "${MOUNT_POINT}" systemctl enable zfs-mount 2>>"${LOG_FILE}" || true
	chroot "${MOUNT_POINT}" systemctl enable zfs-import.target 2>>"${LOG_FILE}" || true

	log "Serviços systemd ZFS habilitados"

	log "Regenerando initramfs..."

	chroot "${MOUNT_POINT}" update-initramfs -c -k all 2>>"${LOG_FILE}" ||
		error_exit "Falha ao regenerar initramfs"

	log "Initramfs regenerado com sucesso"

	# Configurar DKMS para rebuild automático do initramfs quando ZFS for atualizado
	mkdir -p "${MOUNT_POINT}/etc/dkms"
	echo "REMAKE_INITRD=yes" > "${MOUNT_POINT}/etc/dkms/zfs.conf"
	log "DKMS configurado para rebuild automático do initramfs"

	gum format -- "✓ Initramfs regenerado"
}

# =============================================================================
# MÓDULO: INSTALAÇÃO ZFSBOOTMENU
# =============================================================================

# Obter partição EFI do primeiro disco
get_efi_partition() {
	local disk=${SELECTED_DISKS[0]}
	local part_suffix
	part_suffix=$(get_part_suffix "${disk}")

	# Partição 1 agora é ESP (antes era 2)
	echo "${disk}${part_suffix}1"
}

# Formatar partição EFI
format_esp() {
	local efi_part
	efi_part=$(get_efi_partition)

	log "Formatando partição EFI: ${efi_part}"

	mkfs.vfat -F 32 -n EFI "${efi_part}" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao formatar partição EFI ${efi_part}"

	log "Partição EFI formatada com sucesso"
	gum format -- "✓ Partição EFI formatada"
}

# Montar ESP em /boot/efi
mount_esp() {
	local efi_part
	efi_part=$(get_efi_partition)

	log "Montando ESP em ${MOUNT_POINT}/boot/efi..."

	mkdir -p "${MOUNT_POINT}/boot/efi" ||
		error_exit "Falha ao criar diretório ${MOUNT_POINT}/boot/efi"

	mount "${efi_part}" "${MOUNT_POINT}/boot/efi" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao montar ESP em ${MOUNT_POINT}/boot/efi"

	log "ESP montado com sucesso"
	gum format -- "✓ ESP montado em /boot/efi"
}

# Copiar binários do ZFSBootMenu
copy_zbm_binaries() {
	log "Copiando binários do ZFSBootMenu..."

	mkdir -p "${MOUNT_POINT}/boot/efi/EFI/ZBM" ||
		error_exit "Falha ao criar diretório ZBM"

	mkdir -p "${MOUNT_POINT}/boot/efi/EFI/BOOT" ||
		error_exit "Falha ao criar diretório BOOT"

	local zbm_binary=""

	# Primeiro, tentar encontrar binário local (se incluído na ISO pelo download-zfsbootmenu.sh)
	if [[ -d "${ZBM_BIN_DIR}" ]]; then
		log "Procurando binário ZBM local em ${ZBM_BIN_DIR}..."
		log "Conteúdo do diretório:"
		ls -la "${ZBM_BIN_DIR}" >>"${LOG_FILE}" 2>&1 || true

		# Padrões em ordem de preferência (inclui formatos do download-zfsbootmenu.sh)
		for pattern in "VMLINUZ.EFI" "VMLINUZ-RECOVERY.EFI" "release-x86_64.EFI" "recovery-x86_64.EFI" "vmlinuz-bootmenu" "vmlinuz.EFI" "zfsbootmenu.EFI" "*.EFI" "*.efi"; do
			zbm_binary=$(find "${ZBM_BIN_DIR}" -maxdepth 1 -name "${pattern}" -type f 2>/dev/null | grep -vi signed | head -n 1)
			[[ -n "${zbm_binary}" ]] && break
		done
	fi

	# Se não encontrou localmente, baixar da internet (conforme documentação oficial)
	if [[ -z "${zbm_binary}" ]]; then
		log "Binário ZBM não encontrado localmente, baixando da URL oficial..."
		gum format -- "> Baixando ZFSBootMenu de https://get.zfsbootmenu.org/efi..."

		if command -v curl >/dev/null 2>&1; then
			if curl -fsSL -o "${MOUNT_POINT}/boot/efi/EFI/ZBM/VMLINUZ.EFI" "https://get.zfsbootmenu.org/efi" 2>>"${LOG_FILE}"; then
				log "ZFSBootMenu baixado com sucesso"
				# Criar backup
				cp "${MOUNT_POINT}/boot/efi/EFI/ZBM/VMLINUZ.EFI" "${MOUNT_POINT}/boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI" 2>>"${LOG_FILE}" || true
				# Copiar para BOOT como fallback UEFI
				cp "${MOUNT_POINT}/boot/efi/EFI/ZBM/VMLINUZ.EFI" "${MOUNT_POINT}/boot/efi/EFI/BOOT/BOOTX64.EFI" 2>>"${LOG_FILE}" || true
				log "Binários ZFSBootMenu instalados com sucesso"
				gum format -- "✓ ZFSBootMenu baixado e instalado"
				return 0
			else
				log "Falha ao baixar ZFSBootMenu da internet"
			fi
		else
			log "curl não disponível para download"
		fi

		# Se chegou aqui, falhou
		log "Conteúdo de ${ZBM_BIN_DIR} (se existir):"
		ls -la "${ZBM_BIN_DIR}" >>"${LOG_FILE}" 2>&1 || echo "Diretório não existe" >>"${LOG_FILE}"
		error_exit "Binário ZFSBootMenu não encontrado e download falhou. Verifique conexão de rede."
	fi

	# Usar binário local encontrado
	log "Binário ZBM encontrado localmente: ${zbm_binary}"
	cp "${zbm_binary}" "${MOUNT_POINT}/boot/efi/EFI/ZBM/VMLINUZ.EFI" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao copiar binário ZBM"

	# Criar backup
	cp "${zbm_binary}" "${MOUNT_POINT}/boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI" 2>>"${LOG_FILE}" || true

	# Copiar para BOOT como fallback UEFI
	cp "${zbm_binary}" "${MOUNT_POINT}/boot/efi/EFI/BOOT/BOOTX64.EFI" 2>>"${LOG_FILE}" || true

	log "Binários ZFSBootMenu copiados com sucesso"
	gum format -- "✓ Binários ZFSBootMenu copiados"
}

# Configuração de Boot BIOS via Syslinux
configure_bios_boot() {
	log "Configurando Boot BIOS (Legacy) com Syslinux..."
	gum format -- "### Configurando Boot BIOS (Syslinux)"

	local esp_part
	esp_part=$(get_efi_partition)
	local disk=${SELECTED_DISKS[0]}

	# 1. Gravar MBR GPT (gptmbr.bin) no disco
	# Isso permite que a BIOS boote um disco GPT e procure a partição ativa (Legacy Boot)
	local mbr_bin="/usr/lib/syslinux/mbr/gptmbr.bin"
	
	if [[ ! -f "${mbr_bin}" ]]; then
		error_exit "Arquivo MBR não encontrado: ${mbr_bin}. Instale syslinux-common."
	fi

	log "Gravando MBR GPT em ${disk}..."
	# Gravamos apenas os primeiros 440 bytes para não sobrescrever a assinatura do disco
	if ! dd if="${mbr_bin}" of="${disk}" bs=440 count=1 conv=notrunc 2>>"${LOG_FILE}"; then
		error_exit "Falha ao gravar MBR em ${disk}"
	fi

	# 2. Instalar Syslinux na ESP
	# O comando syslinux instala o ldlinux.sys na partição FAT32 sem formatá-la
	log "Instalando Syslinux na partição ${esp_part}..."
	
	# Verificar versão do Syslinux para compatibilidade
	local syslinux_version
	syslinux_version=$(syslinux --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 || echo "unknown")
	log "Versão do Syslinux detectada: ${syslinux_version}"
	
	if ! syslinux --install "${esp_part}" 2>>"${LOG_FILE}"; then
		error_exit "Falha ao instalar Syslinux na partição ${esp_part}"
	fi

	# 3. Configurar syslinux.cfg na ESP
	# O Syslinux procura syslinux.cfg na raiz da partição ou em /boot/syslinux/
	local syslinux_cfg="${MOUNT_POINT}/boot/efi/syslinux.cfg"
	
	log "Criando configuração ${syslinux_cfg}..."
	
	# Verificar compatibilidade de componentes ZBM para Syslinux
	local zbm_dir="${MOUNT_POINT}/boot/efi/zbm"
	mkdir -p "${zbm_dir}"
	
	# Verificar se temos componentes separados ou apenas .EFI
	local vmlinuz_src="${MOUNT_POINT}/boot/efi/zbm/vmlinuz"
	local initramfs_src="${MOUNT_POINT}/boot/efi/zbm/initramfs.img"
	local efi_stub="${MOUNT_POINT}/boot/efi/zbm/VMLINUZ.EFI"
	
	if [[ ! -f "${vmlinuz_src}" ]] && [[ ! -f "${initramfs_src}" ]] && [[ -f "${efi_stub}" ]]; then
		log "⚠ Apenas EFI stub encontrado. Syslinux pode não conseguir bootar."
		log "💡 Tentando extrair componentes do EFI stub..."
		
		# Tentativa de extração (fallback)
		if command -v objcopy >/dev/null 2>&1; then
			objcopy -O binary --only-section=.linux "${efi_stub}" "${vmlinuz_src}" 2>/dev/null || true
			objcopy -O binary --only-section=.initramfs "${efi_stub}" "${initramfs_src}" 2>/dev/null || true
		fi
	fi

	# Tentar copiar componentes separados da fonte original
	local vmlinuz_src="${ZBM_BIN_DIR}/vmlinuz-bootmenu"
	local initramfs_src="${ZBM_BIN_DIR}/initramfs-bootmenu.img"
	
	if [[ -f "${vmlinuz_src}" ]] && [[ -f "${initramfs_src}" ]]; then
		cp "${vmlinuz_src}" "${zbm_dir}/vmlinuz" 2>>"${LOG_FILE}" || log_warn "Falha ao copiar vmlinuz"
		cp "${initramfs_src}" "${zbm_dir}/initramfs.img" 2>>"${LOG_FILE}" || log_warn "Falha ao copiar initramfs"
	else
		# Fallback: Se não temos os componentes separados, tentamos usar o unificado .EFI como kernel
		# (O ZBM .EFI muitas vezes funciona como bzImage)
		log "Componentes separados não encontrados. Tentando usar VMLINUZ.EFI como kernel."
		cp "${MOUNT_POINT}/boot/efi/EFI/ZBM/VMLINUZ.EFI" "${zbm_dir}/vmlinuz" 2>>"${LOG_FILE}" || true
		# Initramfs está embutido no .EFI, então talvez não precisemos de initrd...
		# Mas para ZBM, o .EFI é um bundle.
		# SE estivermos usando o script de download oficial, teriamos os componentes.
		# Vamos assumir que temos os componentes ou erro.
		if [[ ! -f "${zbm_dir}/vmlinuz" ]]; then
			error_exit "Componentes do ZFSBootMenu não encontrados para configuração BIOS."
		fi
	fi

	cat <<EOF >"${syslinux_cfg}"
# Syslinux - Boot direto para ZFSBootMenu (BIOS Legacy)
# Configuração mínima: sem menu, boot imediato
DEFAULT zfsbootmenu
PROMPT 0
TIMEOUT 0

LABEL zfsbootmenu
    LINUX /zbm/vmlinuz
    INITRD /zbm/initramfs.img
    APPEND zbm.prefer_policy=hostid quiet loglevel=0
EOF

	# Nota: Não copiamos menu.c32/libutil.c32 pois usamos boot direto sem menu

	log "Syslinux configurado com sucesso na ESP."
	gum format -- "✓ Syslinux BIOS configurado"
}

# Configurar entrada EFI com efibootmgr
configure_efi() {
	log "Configurando entrada EFI..."

	# Verificar se é sistema UEFI
	if [[ ! -d /sys/firmware/efi ]]; then
		log "Sistema não é UEFI, pulando configuração EFI"
		gum format -- "> ⚠️ Sistema BIOS detectado - EFI não configurado"
		return 0
	fi

	# Verificar se efibootmgr está disponível
	if ! command -v efibootmgr >/dev/null 2>&1; then
		log "efibootmgr não encontrado, pulando configuração EFI"
		gum format -- "> ⚠️ efibootmgr não disponível - EFI não configurado"
		return 0
	fi

	# Montar efivarfs se não estiver montado (necessário em alguns ambientes live)
	if [[ ! -d /sys/firmware/efi/efivars ]] || ! mountpoint -q /sys/firmware/efi/efivars 2>/dev/null; then
		mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>>${LOG_FILE} || true
	fi

	# Criar entrada de backup primeiro (conforme documentação oficial)
	efibootmgr -c -d "${SELECTED_DISKS[0]}" -p 2 \
		-L "ZFSBootMenu (Backup)" \
		-l "\EFI\ZBM\VMLINUZ-BACKUP.EFI" \
		2>>"${LOG_FILE}" || true

	# Criar entrada principal (será a primeira na ordem de boot)
	efibootmgr -c -d "${SELECTED_DISKS[0]}" -p 2 \
		-L "ZFSBootMenu" \
		-l "\EFI\ZBM\VMLINUZ.EFI" \
		2>>"${LOG_FILE}" || {
		log "Falha ao configurar entrada EFI principal"
		gum format -- "> ⚠️ Falha ao configurar entrada EFI - continue manualmente"
		return 0
	}

	log "Entradas EFI configuradas com sucesso (principal + backup)"
	gum format -- "✓ Entradas EFI configuradas"
}

# Configurar propriedade de commandline para ZFSBootMenu
configure_commandline() {
	log "Configurando propriedade de commandline para ZFSBootMenu..."

	zfs set org.zfsbootmenu:commandline="quiet loglevel=4" "${POOL_NAME}/ROOT/debian" 2>>"${LOG_FILE}" ||
		error_exit "Falha ao configurar commandline do ZFSBootMenu"

	log "Propriedade commandline configurada com sucesso"
	gum format -- "✓ Propriedade ZFSBootMenu configurada"
}

# =============================================================================
# MÓDULO: FINALIZAÇÃO
# =============================================================================

# Criar snapshot inicial do sistema
create_snapshot() {
	log "Criando snapshot inicial do sistema..."

	# Verificar se snapshot já existe
	if zfs list -t snapshot | grep -q "${POOL_NAME}/ROOT/debian@install"; then
		log "Snapshot @install já existe, removendo..."
		zfs destroy -r "${POOL_NAME}/ROOT/debian@install" 2>>"${LOG_FILE}" || true
	fi

	if ! zfs snapshot "${POOL_NAME}/ROOT/debian@install" 2>>"${LOG_FILE}"; then
		error_exit "Falha ao criar snapshot inicial"
	fi

	log "Snapshot inicial criado: ${POOL_NAME}/ROOT/debian@install"

	# Garantir que o dataset raiz não monte automaticamente (será montado pelo initramfs)
	zfs set canmount=noauto "${POOL_NAME}/ROOT/debian" 2>>${LOG_FILE} || true
	log "canmount=noauto definido em ${POOL_NAME}/ROOT/debian"

	gum format -- "✓ Snapshot inicial criado"
}

# Desmontar todos os filesystems
unmount_all() {
	log "Desmontando filesystems..."

	# Desmontar sistemas virtuais primeiro
	for dir in dev proc sys run; do
		if mountpoint -q "${MOUNT_POINT}/${dir}"; then
			log "Desmontando ${MOUNT_POINT}/${dir}"
			umount -l "${MOUNT_POINT}/${dir}" 2>>"${LOG_FILE}" || true
		fi
	done

	# Desmontar ESP se estiver montado
	if mountpoint -q "${MOUNT_POINT}/boot/efi"; then
		log "Desmontando ${MOUNT_POINT}/boot/efi"
		umount "${MOUNT_POINT}/boot/efi" 2>>"${LOG_FILE}" || true
	fi

	# Desmontar datasets ZFS em ordem inversa
	if mountpoint -q "${MOUNT_POINT}/var/tmp"; then
		zfs umount "${POOL_NAME}/var/tmp" 2>>"${LOG_FILE}" || true
	fi
	if mountpoint -q "${MOUNT_POINT}/var/cache"; then
		zfs umount "${POOL_NAME}/var/cache" 2>>"${LOG_FILE}" || true
	fi
	if mountpoint -q "${MOUNT_POINT}/var/log"; then
		zfs umount "${POOL_NAME}/var/log" 2>>"${LOG_FILE}" || true
	fi
	if mountpoint -q "${MOUNT_POINT}/home"; then
		zfs umount "${POOL_NAME}/home" 2>>"${LOG_FILE}" || true
	fi
	if mountpoint -q "${MOUNT_POINT}/home/root"; then
		zfs umount "${POOL_NAME}/home/root" 2>>"${LOG_FILE}" || true
	fi
	if mountpoint -q "${MOUNT_POINT}"; then
		zfs umount "${POOL_NAME}/ROOT/debian" 2>>"${LOG_FILE}" || true
	fi

	sync
	log "Filesystems desmontados"
	gum format -- "✓ Filesystems desmontados"
}

# Exportar pool ZFS
export_pool() {
	log "Exportando pool ZFS..."

	if zpool export "${POOL_NAME}" 2>>"${LOG_FILE}"; then
		log "Pool ${POOL_NAME} exportado com sucesso"
		gum format -- "✓ Pool ZFS exportado"
	else
		log "Aviso: Falha ao exportar pool ${POOL_NAME}"
		gum format -- "> ⚠️ Aviso: Não foi possível exportar o pool ZFS"
	fi
}

# Remover pacotes do GRUB do sistema instalado
remove_grub_packages() {
	log "Removendo pacotes do GRUB para evitar conflitos..."
	gum format -- "### Removendo GRUB (Proteção)"

	# Lista de pacotes para remover
	local packages="grub-pc grub-efi-amd64-bin grub-common os-prober"

	if ! chroot "${MOUNT_POINT}" apt-get purge -y ${packages} 2>>"${LOG_FILE}"; then
		log_warn "Falha ao remover alguns pacotes do GRUB (talvez não estivessem instalados)"
	fi
	
	# Garantir autoremove para limpar dependências órfãs
	chroot "${MOUNT_POINT}" apt-get autoremove -y 2>>"${LOG_FILE}" || true

	log "Pacotes GRUB removidos."
	gum format -- "✓ GRUB removido do sistema alvo"
}

# Configurar console avançado para perfil Server
# Suporte a framebuffer, mouse (GPM), cores 256/truecolor e emojis
configure_advanced_console() {
	log "Configurando console avançado para ambiente texto..."
	gum format -- "### Configurando Console Avançado"

	# === 1. Habilitar GPM para suporte a mouse no console ===
	if chroot "${MOUNT_POINT}" command -v gpm >/dev/null 2>&1; then
		chroot "${MOUNT_POINT}" systemctl enable gpm 2>>"${LOG_FILE}" || true
		log "GPM (suporte a mouse) habilitado"
		
		# Configurar GPM para modo repetidor (útil para terminais como screen/tmux)
		cat <<'EOF' >"${MOUNT_POINT}/etc/gpm.conf"
# Configuração GPM para FileServer OS Server
device=/dev/input/mice
responsiveness=
repeat_type=ms3
type=exps2
append=""
sample_rate=
EOF
		log "Configuração GPM criada"
	fi

	# === 2. Configurar console-setup para UTF-8 e fonte com suporte a emojis ===
	cat <<'EOF' >"${MOUNT_POINT}/etc/default/console-setup"
# Console setup para FileServer OS - Suporte UTF-8 e caracteres especiais
ACTIVE_CONSOLES="/dev/tty[1-6]"
CHARMAP="UTF-8"
CODESET="Lat15"
FONTFACE="Terminus"
FONTSIZE="16x32"
EOF
	log "Console-setup configurado para UTF-8"

	# === 3. Configurar kernel cmdline para framebuffer avançado ===
	# O ZFSBootMenu usa a propriedade org.zfsbootmenu:commandline
	# Adicionar parâmetros de framebuffer se não existirem
	local current_cmdline
	current_cmdline=$(zfs get -H -o value org.zfsbootmenu:commandline "${POOL_NAME}/ROOT/debian" 2>/dev/null || echo "quiet")
	
	# Remover loglevel se existir e adicionar parâmetros de framebuffer
	local new_cmdline="${current_cmdline}"
	
	# Adicionar fbcon se não existir
	if ! echo "${new_cmdline}" | grep -q "fbcon"; then
		new_cmdline="${new_cmdline} fbcon=nodefer,font:TER16x32"
	fi
	
	# Garantir 256 cores via TERM
	if ! echo "${new_cmdline}" | grep -q "vt.default_red"; then
		# Paleta de cores personalizada Aurora (tons de azul/roxo)
		new_cmdline="${new_cmdline} vt.default_red=0,170,0,170,0,170,0,170,85,255,85,255,85,255,85,255"
		new_cmdline="${new_cmdline} vt.default_grn=0,0,170,85,0,0,170,170,85,85,255,255,85,85,255,255"
		new_cmdline="${new_cmdline} vt.default_blu=0,0,0,0,170,170,170,170,85,85,85,85,255,255,255,255"
	fi
	
	zfs set org.zfsbootmenu:commandline="${new_cmdline}" "${POOL_NAME}/ROOT/debian" 2>>"${LOG_FILE}" || true
	log "Kernel cmdline atualizado com parâmetros de framebuffer"

	# === 4. Criar perfil de terminal avançado em /etc/profile.d ===
	cat <<'EOF' >"${MOUNT_POINT}/etc/profile.d/fileserver-console.sh"
# FileServer OS - Configuração de Console Avançado
# Suporte a cores 256, UTF-8 e emojis

# Detectar e configurar TERM corretamente
if [ "$TERM" = "linux" ]; then
    # Console Linux padrão - tentar usar 256 cores se disponível
    if [ -d /sys/module/fbcon ]; then
        export TERM="linux"
        # Habilitar cores estendidas via escape sequences
        export COLORTERM="truecolor"
    fi
fi

# Configurar locale para UTF-8 (suporte a emojis)
export LANG="${LANG:-pt_BR.UTF-8}"
export LC_ALL="${LC_ALL:-pt_BR.UTF-8}"

# Histórico melhorado
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoreboth:erasedups

# Prompt colorido para console
if [ -z "$SSH_CLIENT" ] && [ "$TERM" = "linux" ]; then
    # Console local - prompt FileServer
    PS1='\[\e[1;35m\][\u@\h \W]\$\[\e[0m\] '
else
    # SSH ou outro terminal - prompt padrão
    PS1='\[\e[1;32m\][\u@\h \W]\$\[\e[0m\] '
fi

# Aliases úteis para modo servidor
alias ll='ls -la --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias top='htop 2>/dev/null || top'
EOF
	chmod 644 "${MOUNT_POINT}/etc/profile.d/fileserver-console.sh"
	log "Perfil de console FileServer criado"

	# === 5. Configurar getty para auto-login opcional (desabilitado por padrão) ===
	# Criar override para getty@tty1 com configurações otimizadas
	mkdir -p "${MOUNT_POINT}/etc/systemd/system/getty@tty1.service.d"
	cat <<'EOF' >"${MOUNT_POINT}/etc/systemd/system/getty@tty1.service.d/override.conf"
[Service]
# Garantir que getty use UTF-8 e configurações de terminal corretas
Environment="LANG=pt_BR.UTF-8"
Environment="TERM=linux"
EOF
	log "Override do getty@tty1 criado"

	gum format -- "✓ Console avançado configurado (GPM, UTF-8, cores)"
}

# Configuração de perfis e pacotes adicionais
configure_profile() {
	gum format -- "### Configurando Perfil: **${PROFILE}**"
	log "Iniciando configuração do perfil ${PROFILE}..."

	if [[ "${PROFILE}" == "Workstation" ]]; then
		log "Configurando Workstation (habilitando interface gráfica)..."
		
		# Definir target gráfico como padrão
		chroot "${MOUNT_POINT}" systemctl set-default graphical.target 2>>"${LOG_FILE}" || true
		
		# Habilitar display manager disponível (prioridade: sddm > lightdm > gdm)
		if chroot "${MOUNT_POINT}" command -v sddm >/dev/null 2>&1; then
			chroot "${MOUNT_POINT}" systemctl enable sddm 2>>"${LOG_FILE}" || true
			log "SDDM habilitado como display manager"
		elif chroot "${MOUNT_POINT}" command -v lightdm >/dev/null 2>&1; then
			chroot "${MOUNT_POINT}" systemctl enable lightdm 2>>"${LOG_FILE}" || true
			log "LightDM habilitado como display manager"
		fi
	else
		log "Configurando Server (modo console avançado)..."
		
		# === 1. Definir target multi-user (sem GUI) como padrão ===
		chroot "${MOUNT_POINT}" systemctl set-default multi-user.target 2>>"${LOG_FILE}" || true
		log "Target definido como multi-user.target"
		
		# === 2. Desabilitar TODOS os display managers conhecidos ===
		local display_managers=("sddm" "lightdm" "gdm" "gdm3" "xdm" "lxdm" "nodm" "slim" "wdm")
		for dm in "${display_managers[@]}"; do
			if chroot "${MOUNT_POINT}" systemctl is-enabled "${dm}" 2>/dev/null | grep -q "enabled"; then
				chroot "${MOUNT_POINT}" systemctl disable "${dm}" 2>>"${LOG_FILE}" || true
				log "Display manager ${dm} desabilitado"
			fi
			# Também mascarar para garantir que não seja iniciado acidentalmente
			chroot "${MOUNT_POINT}" systemctl mask "${dm}" 2>>"${LOG_FILE}" || true
		done
		
		# === 3. Garantir que getty está habilitado no tty1 ===
		chroot "${MOUNT_POINT}" systemctl unmask getty@tty1 2>>"${LOG_FILE}" || true
		chroot "${MOUNT_POINT}" systemctl enable getty@tty1 2>>"${LOG_FILE}" || true
		log "getty@tty1 habilitado"
		
		# === 4. Configurar console avançado com framebuffer ===
		configure_advanced_console
		
		log "Perfil Server configurado com sucesso"
	fi
}

# Exibir mensagem de sucesso e instruções
success_message() {
	local encryption_note=""
	if [[ "${ENCRYPTION}" == "on" ]]; then
		encryption_note="\n\n> 🔐 **Nota:** O ZFSBootMenu solicitará sua passphrase para desbloquear o sistema."
	fi

	styled_box "${COLOR_SUCCESS}" "🎉 INSTALAÇÃO CONCLUÍDA" \
		"O **FileServer OS** foi instalado com sucesso!" \
		"" \
		"**Configuração Realizada:**" \
		"• Hostname:  ${HOSTNAME}" \
		"• Usuário:   ${USERNAME}" \
		"• Perfil:    ${PROFILE}" \
		"• Crypto:    ${ENCRYPTION}" \
		"" \
		"**Próximos Passos:**" \
		"1. Remova a mídia de instalação" \
		"2. Reinicie o sistema" \
		"3. Selecione 'FileServer OS' no boot" \
		"" \
		"${encryption_note}" \
		"" \
		"**Snapshots:**" \
		"Use ZFSBootMenu para gerenciar snapshots e rollbacks."

	log "=== Instalação concluída com sucesso ==="
}

# =============================================================================
# FUNÇÃO PRINCIPAL
# =============================================================================

main() {
	log "=== Iniciando ${SCRIPT_NAME} v${SCRIPT_VERSION} ==="

	# Fase 1: Pré-requisitos
	preflight_checks

	# Fase 2: Interface TUI
	welcome_screen
	select_disks
	
	# Selecionar topologia baseada no número de discos
	if [[ ${#SELECTED_DISKS[@]} -eq 1 ]]; then
		RAID_TOPOLOGY="Single"
		log "Único disco selecionado, topologia definida como Single"
	else
		select_topology
	fi

	select_profile

	configure_zfs_options
	collect_info
	confirm_installation

	# Fase 3: Preparação do Disco
	prepare_disks

	# Fase 4: Configuração ZFS
	create_pool
	create_datasets

	# Fase 5: Extração do Sistema
	validate_squashfs
	create_essential_dirs
	extract_system

	# Fase 6: Configuração Chroot
	mount_chroot_filesystems
	configure_hostname
	configure_users
	configure_locales
	configure_profile
	configure_fstab
	generate_hostid
	remove_grub_packages
	update_initramfs

	# Fase 7: Instalação ZFSBootMenu
	format_esp
	mount_esp
	copy_zbm_binaries
	# Detectar firmware e configurar bootloader apropriado
	if [[ -d /sys/firmware/efi ]]; then
		configure_efi
	else
		configure_bios_boot
	fi
	configure_commandline

	# Fase 8: Finalização
	create_snapshot
	unmount_all
	export_pool
	success_message

	log "=== Instalação concluída ==="
}

main "$@"
