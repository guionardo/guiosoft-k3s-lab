SHELL := /bin/bash

.PHONY: help discovery ansible-deps preflight bootstrap tools k3s storage storage-test storage-test-status storage-test-recreate storage-test-delete firewall-audit cluster-status lab-deploy lab-status lab-test lab-delete tf-cloudflare-discovery tf-cloudflare-init tf-cloudflare-fmt tf-cloudflare-validate tf-cloudflare-import tf-cloudflare-plan

help:
	@echo "guiosoft-k3s-lab"
	@echo
	@echo "Targets disponíveis:"
	@echo "  make discovery             Executa discovery read-only deste host"
	@echo "  make ansible-deps          Instala Ansible e collections necessárias"
	@echo "  make preflight             Valida DNS, Tailscale, portas e serviços preservados"
	@echo "  make bootstrap             Prepara Debian e ferramentas de IaC para K3s"
	@echo "  make tools                 Instala/valida ferramentas de IaC no host"
	@echo "  make k3s                   Instala/valida K3s, kubectl e local-path dedicado"
	@echo "  make storage               Prepara layout persistente sem mover ou apagar dados"
	@echo "  make storage-test          Cria PVC + Deployment para testar persistência"
	@echo "  make storage-test-status   Mostra PVC/PV/Pod e o marker persistente"
	@echo "  make storage-test-recreate Remove o Pod e valida persistência após recriação"
	@echo "  make storage-test-delete   Remove workload e PVC de teste"
	@echo "  make firewall-audit        Audita firewall/listeners após K3s sem alterar regras"
	@echo "  make cluster-status        Mostra nodes, pods e services do cluster"
	@echo "  make lab-deploy            Cria namespace e workload de teste"
	@echo "  make lab-status            Mostra recursos do workload de teste"
	@echo "  make lab-test              Testa o Ingress localmente via Traefik"
	@echo "  make lab-delete            Remove o workload de teste"
	@echo "  make tf-cloudflare-discovery Descobre IDs existentes sem imprimir tokens"
	@echo "  make tf-cloudflare-init    Inicializa provider Terraform da Cloudflare"
	@echo "  make tf-cloudflare-fmt     Valida formatação Terraform"
	@echo "  make tf-cloudflare-validate Valida configuração Terraform"
	@echo "  make tf-cloudflare-import  Importa recursos existentes para o state local"
	@echo "  make tf-cloudflare-plan    Mostra plano Cloudflare sem aplicar mudanças"

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

tools:
	cd ansible && ansible-playbook -K playbooks/tools.yml

k3s:
	cd ansible && ansible-playbook -K playbooks/k3s.yml

storage:
	cd ansible && ansible-playbook -K playbooks/storage.yml

storage-test:
	kubectl apply -f kubernetes/namespaces/lab.yaml
	kubectl apply -f kubernetes/storage/persistence-test.yaml
	kubectl rollout status deployment/persistence-test -n lab --timeout=120s
	$(MAKE) storage-test-status

storage-test-status:
	kubectl get pvc persistence-test -n lab -o wide
	kubectl get pv -o wide
	kubectl get pods -n lab -l app=persistence-test -o wide
	@POD=$$(kubectl get pod -n lab -l app=persistence-test -o jsonpath='{.items[0].metadata.name}'); \
	  echo "Marker from $$POD:"; \
	  kubectl exec -n lab "$$POD" -- cat /data/marker.txt

storage-test-recreate:
	@OLD_POD=$$(kubectl get pod -n lab -l app=persistence-test -o jsonpath='{.items[0].metadata.name}'); \
	  echo "Deleting $$OLD_POD"; \
	  kubectl delete pod -n lab "$$OLD_POD" --wait=true; \
	  kubectl wait -n lab --for=condition=Ready pod -l app=persistence-test --timeout=120s; \
	  NEW_POD=$$(kubectl get pod -n lab -l app=persistence-test -o jsonpath='{.items[0].metadata.name}'); \
	  echo "Recreated as $$NEW_POD"; \
	  kubectl exec -n lab "$$NEW_POD" -- cat /data/marker.txt

storage-test-delete:
	kubectl delete -f kubernetes/storage/persistence-test.yaml --ignore-not-found

firewall-audit:
	cd ansible && ansible-playbook -K playbooks/firewall-audit.yml

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

tf-cloudflare-discovery:
	bash scripts/cloudflare-discovery.sh

tf-cloudflare-init:
	cd terraform/cloudflare && terraform init

tf-cloudflare-fmt:
	cd terraform/cloudflare && terraform fmt -check -recursive

tf-cloudflare-validate:
	cd terraform/cloudflare && terraform validate

tf-cloudflare-import:
	bash scripts/cloudflare-import.sh

tf-cloudflare-plan:
	cd terraform/cloudflare && terraform plan
