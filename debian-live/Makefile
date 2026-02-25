# Makefile para ISO Live Debian Trixie ZFS

.PHONY: all clean build test install help

PROJECT_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
BUILD_DIR := $(PROJECT_DIR)

all: build

## build: Constrói a ISO
build:
	@echo "==> Construindo ISO Live..."
	@cd $(PROJECT_DIR) && sudo bash provision-debian-live.sh

## clean: Limpa build anterior
clean:
	@echo "==> Limpando build anterior..."
	@cd $(PROJECT_DIR)/debian-live && sudo lb clean --all
	@echo "==> Removendo ISOs..."
	@rm -f $(PROJECT_DIR)/debian-live/*.iso
	@rm -f $(PROJECT_DIR)/debian-live/*.img
	@echo "==> Limpando logs..."
	@rm -f $(PROJECT_DIR)/build.log

## test: Testa a ISO no QEMU
test:
	@ISO=$$(ls -t $(PROJECT_DIR)/debian-live/*.iso 2>/dev/null | head -1); \
	if [ -z "$$ISO" ]; then \
		echo "ERRO: Nenhuma ISO encontrada. Execute 'make build' primeiro."; \
		exit 1; \
	fi; \
	echo "==> Testando ISO em QEMU..."; \
	qemu-system-x86_64 -m 4096 -smp 4 -cdrom "$$ISO" -boot d -accel kvm -cpu host

## test-no-kvm: Testa sem KVM (mais lento)
test-no-kvm:
	@ISO=$$(ls -t $(PROJECT_DIR)/debian-live/*.iso 2>/dev/null | head -1); \
	if [ -z "$$ISO" ]; then \
		echo "ERRO: Nenhuma ISO encontrada. Execute 'make build' primeiro."; \
		exit 1; \
	fi; \
	echo "==> Testando ISO em QEMU (sem KVM)..."; \
	qemu-system-x86_64 -m 4096 -smp 4 -cdrom "$$ISO" -boot d

## install-deps: Instala dependências do build
install-deps:
	@echo "==> Instalando dependências..."
	@if command -v apt-get >/dev/null 2>&1; then \
		sudo apt-get update; \
		sudo apt-get install -y live-build; \
	elif command -v pacman >/dev/null 2>&1; then \
		sudo pacman -S --noconfirm live-build; \
	elif command -v dnf >/dev/null 2>&1; then \
		sudo dnf install -y live-build; \
	else \
		echo "ERRO: Gerenciador de pacotes não suportado"; \
		exit 1; \
	fi

## help: Mostra esta ajuda
help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets disponíveis:"
	@sed -n 's/^## //p' $(MAKEFILE_LIST) | column -t -s ':'
