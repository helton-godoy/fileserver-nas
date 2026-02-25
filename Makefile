# Makefile para formatação e linting de scripts shell
# Uso: make <target>

.PHONY: all format lint check fix clean help

# Diretórios
SCRIPTS_DIR := .
SH_FILES := $(shell find $(SCRIPTS_DIR) -name "*.sh" -type f)

# Ferramentas
SHFMT := shfmt
SHELLCHECK := shellcheck
BASHATE := bashate
BEAUTYSH := beautysh

# Opções do shfmt
SHFMT_OPTS := -i 4 -sr -ci -s -bn -w

# Opções do shellcheck
SHELLCHECK_OPTS := -x -a -s bash

# Opções do bashate
BASHATE_OPTS := -i E006

all: format lint

## format: Formata todos os scripts shell
format:
	@echo "==> Formatando scripts shell..."
	@for file in $(SH_FILES); do \
		echo "   Formatando: $$file"; \
		$(SHFMT) $(SHFMT_OPTS) "$$file" 2>/dev/null || true; \
	done
	@echo "==> Formatação concluída!"

## lint: Executa todos os linters
lint: shellcheck bashate
	@echo "==> Linting concluído!"

## shellcheck: Executa shellcheck
shellcheck:
	@echo "==> Executando shellcheck..."
	@for file in $(SH_FILES); do \
		echo "   Verificando: $$file"; \
		$(SHELLCHECK) $(SHELLCHECK_OPTS) "$$file" 2>/dev/null || true; \
	done

## bashate: Executa bashate
bashate:
	@echo "==> Executando bashate..."
	@for file in $(SH_FILES); do \
		echo "   Verificando: $$file"; \
		$(BASHATE) $(BASHATE_OPTS) "$$file" 2>/dev/null || true; \
	done

## check: Verifica sem modificar (dry-run)
check:
	@echo "==> Verificando formatação..."
	@for file in $(SH_FILES); do \
		if ! $(SHFMT) -d "$$file" > /dev/null 2>&1; then \
			echo "   Precisa formatação: $$file"; \
		fi; \
	done
	@echo "==> Verificação concluída!"

## fix: Corrige problemas automaticamente
fix: format
	@echo "==> Problemas corrigidos!"

## clean: Remove arquivos temporários
clean:
	@echo "==> Limpando arquivos temporários..."
	@find $(SCRIPTS_DIR) -name "*.bak" -type f -delete 2>/dev/null || true
	@find $(SCRIPTS_DIR) -name "*~" -type f -delete 2>/dev/null || true
	@echo "==> Limpeza concluída!"

## test: Executa verificação de sintaxe
test:
	@echo "==> Verificando sintaxe bash..."
	@for file in $(SH_FILES); do \
		echo "   Testando: $$file"; \
		bash -n "$$file" || exit 1; \
	done
	@echo "==> Todos os scripts passaram na verificação de sintaxe!"

## help: Mostra esta ajuda
help:
	@echo "Uso: make [target]"
	@echo ""
	@echo "Targets disponíveis:"
	@sed -n 's/^## //p' $(MAKEFILE_LIST) | column -t -s ':'
