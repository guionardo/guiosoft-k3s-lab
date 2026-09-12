SHELL := /bin/bash

.PHONY: help discovery ansible-deps preflight bootstrap k3s cluster-status

help:
	@echo "guiosoft-k3s-lab"
	@echo
	@echo "Targets disponíveis:"
	@echo "  make discovery      Executa discovery read-only deste host"
	@echo "  make ansible-deps   Instala Ansible e collections necessárias"
	@echo "  make preflight      Valida DNS, Tailscale, portas e serviços preservados"
	@echo "  make bootstrap      Prepara o Debian para K3s (não instala o cluster)"
	@echo "  make k3s            Instala/valida a versão fixada do K3s"
	@echo "  make cluster-status Mostra nodes, pods e services do cluster"

# Use sudo because some useful inventory information is only visible to root.
discovery:
	sudo bash scripts/discovery.sh

ansible-deps:
	sudo apt-get update
	sudo apt-get install -y ansible-core
	cd ansible && ansible-galaxy collection install -r requirements.yml

preflight:
	cd ansible && ansible-playbook playbooks/preflight.yml

bootstrap:
	cd ansible && ansible-playbook playbooks/bootstrap.yml

k3s:
	cd ansible && ansible-playbook playbooks/k3s.yml

cluster-status:
	sudo k3s kubectl get nodes -o wide
	sudo k3s kubectl get pods -A -o wide
	sudo k3s kubectl get services -A
