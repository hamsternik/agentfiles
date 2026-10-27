# agentfiles — reproducible agent machines. Mirrors the dotfiles Makefile style.
SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help deps host cockpit dry-run-host dry-run-cockpit doctor hooks lint test secrets-scan path

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

deps: ## Install repo dependencies (gitleaks, shellcheck, yq, jq) from ./Brewfile
	brew bundle --file Brewfile

host: hooks ## Bootstrap this Mac as the always-on agent host
	./bootstrap.sh host

cockpit: hooks ## Bootstrap this Mac as the cockpit (client side)
	./bootstrap.sh cockpit

dry-run-host: ## Print what host bootstrap would do
	./bootstrap.sh host --dry-run

dry-run-cockpit: ## Print what cockpit bootstrap would do
	./bootstrap.sh cockpit --dry-run

doctor: ## Check this machine against its role
	bin/af doctor

hooks: ## Install git hooks (gitleaks + denylist) for this repo
	git config core.hooksPath hooks

lint: ## shellcheck every script
	shellcheck -x bootstrap.sh lib/*.sh bin/* roles/*/steps/*.sh hooks/* tests/*.sh

test: ## Run tests under macOS /bin/bash 3.2
	@for t in tests/*.test.sh; do echo "== $$t"; /bin/bash "$$t" || exit 1; done

secrets-scan: ## Scan full git history for secrets
	gitleaks git --redact --config .gitleaks.toml .

path: ## Print the line to add bin/ to PATH
	@echo 'fish_add_path $(CURDIR)/bin   # fish'
	@echo 'export PATH="$(CURDIR)/bin:$$PATH"   # zsh/bash'
