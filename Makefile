# NixOS K8s - Declarative K3s cluster on NixOS
FLAKE    := .
NIX_EVAL := nix eval --raw --impure

# Read cluster-wide config
ADMIN = $(shell $(NIX_EVAL) --expr '(import ./config.nix).adminUser')

# Get a node's IP: $(call node-ip,server1)
node-ip = $(shell $(NIX_EVAL) --expr '(import ./config.nix).nodes.$(1).ip')

# Get the bootstrap node name
bootstrap-node = $(shell $(NIX_EVAL) --expr 'let c = import ./config.nix; in builtins.head (builtins.filter (n: c.nodes.$${n}.bootstrap or false) (builtins.attrNames c.nodes))')

.PHONY: help setup install deploy deploy-all bootstrap ssh unlock status logs shell fmt check clean reinstall

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## Run interactive setup wizard
	@./scripts/setup.sh

install: config.nix ## Install a node: make install NODE=server1 [IP=x.x.x.x]
	@[ -n "$(NODE)" ] || { echo "Usage: make install NODE=<name> [IP=<live-usb-ip>]"; exit 1; }
	@NODE_IP=$${IP:-$(call node-ip,$(NODE))}; \
	echo "Target: $$NODE_IP (node: $(NODE))"; \
	echo ""; \
	./scripts/install.sh $(NODE) $$NODE_IP

deploy: config.nix ## Deploy to a node: make deploy NODE=server1
	@[ -n "$(NODE)" ] || { echo "Usage: make deploy NODE=<name>"; exit 1; }
	@NODE_IP=$(call node-ip,$(NODE)); \
	IDENTITY=$$($(NIX_EVAL) --expr '(import ./config.nix).agenixIdentity or ""' | sed "s|~|$$HOME|"); \
	SSHOPTS=""; \
	[ -n "$$IDENTITY" ] && SSHOPTS="-o IdentityFile=$$IDENTITY -o IdentitiesOnly=yes"; \
	echo "=== Deploying $(NODE) ($$NODE_IP) ==="; \
	NIX_SSHOPTS="$$SSHOPTS" nixos-rebuild switch --flake $(FLAKE)#$(NODE) \
		--target-host $(ADMIN)@$$NODE_IP --sudo --ask-sudo-password

deploy-all: config.nix ## Deploy to all nodes (servers first)
	@for node in $$(nix eval --json --impure --expr 'builtins.attrNames (import ./config.nix).nodes' | jq -r '.[]'); do \
		$(MAKE) deploy NODE=$$node; \
	done

bootstrap: config.nix ## Bootstrap cluster: deploy server, wait, then all
	@BOOT=$$($(MAKE) -s _bootstrap-name); \
	echo "=== Bootstrapping from $$BOOT ==="; \
	$(MAKE) deploy NODE=$$BOOT; \
	echo "Waiting 60s for infrastructure..."; \
	sleep 60; \
	$(MAKE) deploy-all

_bootstrap-name:
	@echo $(bootstrap-node)

ssh: config.nix ## SSH into a node: make ssh NODE=server1
	@[ -n "$(NODE)" ] || { echo "Usage: make ssh NODE=<name>"; exit 1; }
	@ssh $(ADMIN)@$(call node-ip,$(NODE))

unlock: config.nix ## SSH-unlock a node's LUKS disk via initrd: make unlock NODE=server1
	@[ -n "$(NODE)" ] || { echo "Usage: make unlock NODE=<name>"; exit 1; }
	@./scripts/unlock.sh $(NODE)

status: config.nix ## Show cluster status
	@BOOT=$(bootstrap-node); \
	ssh $(ADMIN)@$$($(NIX_EVAL) --expr "(import ./config.nix).nodes.$$BOOT.ip") \
		'sudo kubectl get nodes -o wide && echo "" && sudo kubectl get pods -A'

logs: config.nix ## Show K3s logs: make logs NODE=server1
	@[ -n "$(NODE)" ] || { echo "Usage: make logs NODE=<name>"; exit 1; }
	@ssh $(ADMIN)@$(call node-ip,$(NODE)) 'journalctl -u "k3s*" --no-pager -n 50'

shell: ## Enter nix dev shell
	nix develop

fmt: ## Format all .nix files
	nix fmt

check: config.nix ## Build all node configs without deploying
	@for node in $$(nix eval --json --impure --expr 'builtins.attrNames (import ./config.nix).nodes' | jq -r '.[]'); do \
		echo "Checking $$node..."; \
		nixos-rebuild build --flake $(FLAKE)#$$node || exit 1; \
	done
	@echo "All nodes OK"

reinstall: config.nix ## Force reinstall a service: make reinstall SVC=docker-mirror [NODE=x]
	@[ -n "$(SVC)" ] || { echo "Usage: make reinstall SVC=<name> [NODE=<name>]"; exit 1; }
	@_NODE=$${NODE:-$$($(MAKE) -s _bootstrap-name)}; \
	NODE_IP=$$($(NIX_EVAL) --expr "(import ./config.nix).nodes.$$_NODE.ip"); \
	echo "=== Reinstalling $(SVC) on $$_NODE ($$NODE_IP) ==="; \
	ssh $(ADMIN)@$$NODE_IP "sudo rm -f /var/lib/$(SVC)-setup-done && sudo systemctl restart $(SVC)-setup.service" && \
	echo "Done." || echo "Failed."

clean: ## Remove build artifacts
	rm -rf result result-*
