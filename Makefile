SHELL := /bin/bash

.PHONY: help discovery ansible-deps preflight bootstrap k3s cluster-status lab-deploy lab-status lab-test lab-delete

help:
	@echo "guiosoft-k3s-lab"
	@echo
	@echo "Targets disponíveis:"
	@echo "  make discovery      Executa discovery read-only deste host"
	@echo "  make ansible-deps   Instala Ansible e collections necessárias"
	@echo "  make preflight      Valida DNS, Tailscale, portas e serviços preservados"
	@echo "  make bootstrap      Prepara o Debian para K3s (não instala o cluster)"
	@echo "  make k3s            Instala/valida a versão fixada do K3s e configura kubectl"
	@echo "  make cluster-status Mostra nodes, pods e services do cluster"
	@echo "  make lab-deploy     Cria namespace e workload de teste"
	@echo "  make lab-status     Mostra recursos do workload de teste"
	@echo "  make lab-test       Testa o Ingress localmente via Traefik"
	@echo "  make lab-delete     Remove o workload de teste"

# Use sudo because some useful inventory information is only visible to root.
discovery:
	sudo bash scripts/discovery.sh

ansible-deps:
	sudo apt-get update
	sudo apt-get install -y ansible-core
	cd ansible && ansible-galaxy collection install -r requirements.yml

# -K asks interactively for the local sudo/become password.
preflight:
	cd ansible && ansible-playbook -K playbooks/preflight.yml

bootstrap:
	cd ansible && ansible-playbook -K playbooks/bootstrap.yml

k3s:
	cd ansible && ansible-playbook -K playbooks/k3s.yml

cluster-status:
	kubectl get nodes -o wide
	kubectl get pods -A -o wide
	kubectl get services -A

lab-deploy:
	kubectl apply -f kubernetes/namespaces/lab.yaml
	kubectl apply -f kubernetes/apps/k3s-test/

lab-status:
	kubectl get all -n lab -o wide
	kubectl get ingress -n lab -o wide

lab-test:
	curl --fail --show-error --silent -H 'Host: k3s-test.guiosoft.info' http://127.0.0.1/

lab-delete:
	kubectl delete -f kubernetes/apps/k3s-test/ --ignore-not-found
	kubectl delete -f kubernetes/namespaces/lab.yaml --ignore-not-found
