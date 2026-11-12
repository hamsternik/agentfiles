# agentfiles — reproducible agent machines. Mirrors the dotfiles Makefile style.
SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help deps slave master dry-run-slave dry-run-master doctor hooks lint test e2e-power remote-step secrets-scan path

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

deps: ## Install repo dependencies (gitleaks, shellcheck, yq, jq) from ./Brewfile
	brew bundle --no-upgrade --file Brewfile

slave: hooks ## Bootstrap this Mac as the slave (always-on agent host)
	./bootstrap.sh slave

master: hooks ## Bootstrap this Mac as the master (client side)
	./bootstrap.sh master

dry-run-slave: ## Print what slave bootstrap would do
	./bootstrap.sh slave --dry-run

dry-run-master: ## Print what master bootstrap would do
	./bootstrap.sh master --dry-run

doctor: ## Check this machine against its role
	bin/af doctor

hooks: ## Install git hooks (gitleaks + denylist) for this repo
	git config core.hooksPath hooks

lint: ## shellcheck every script
	shellcheck -x bootstrap.sh lib/*.sh bin/* roles/*/steps/*.sh hooks/* tests/*.sh tests/e2e/*.sh claude/skills/*/scripts/*.sh

test: ## Run tests under macOS /bin/bash 3.2
	@for t in tests/*.test.sh; do echo "== $$t"; /bin/bash "$$t" || exit 1; done

e2e-power: ## Check the power step on a real host: make e2e-power TARGET=user@host
	@tests/e2e/power.e2e.sh "$(TARGET)"

remote-step: ## Run one step of this working tree on a real host: make remote-step TARGET=user@host STEP=15 VARS="AF_LID_CLOSED=1"
	@tests/e2e/remote-step.sh "$(TARGET)" "$(STEP)" $(VARS)

secrets-scan: ## Scan full git history for secrets
	gitleaks git --redact --config .gitleaks.toml .

path: ## Print the line to add bin/ to PATH
	@echo 'fish_add_path $(CURDIR)/bin   # fish'
	@echo 'export PATH="$(CURDIR)/bin:$$PATH"   # zsh/bash'
