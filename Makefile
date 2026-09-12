SHELL := /bin/bash

.PHONY: help discovery ansible-deps preflight bootstrap tools k3s storage storage-test storage-test-status storage-test-recreate storage-test-reprovision storage-test-delete backup-create backup-list backup-verify backup-install backup-status backup-run backup-prune backup-inventory restic-test restic-r2-secret restic-r2-install restic-r2-test restic-r2-sync restic-r2-status restic-r2-check firewall-audit cluster-status lab-deploy lab-status lab-test lab-delete secrets-test secret-edit secret-view secret-validate secret-apply tf-cloudflare-discovery tf-cloudflare-init tf-cloudflare-fmt tf-cloudflare-validate tf-cloudflare-import tf-cloudflare-plan tf-r2-init tf-r2-fmt tf-r2-validate tf-r2-plan tf-r2-apply

help:
	@echo "guiosoft-k3s-lab"
	@echo
	@echo "Targets disponíveis:"
	@echo "  make discovery             Executa discovery read-only deste host"
	@echo "  make ansible-deps          Instala Ansible e collections necessárias"
	@echo "  make preflight             Valida DNS, Tailscale, portas e serviços preservados"
	@echo "  make bootstrap             Prepara Debian e ferramentas de IaC para K3s"
	@echo "  make tools                 Instala/valida Terraform, SOPS, age e restic"
	@echo "  make k3s                   Instala/valida K3s, kubectl e local-path dedicado"
	@echo "  make storage               Prepara layout persistente sem mover ou apagar dados"
	@echo "  make storage-test          Cria PVC + Deployment para testar persistência"
	@echo "  make storage-test-status   Mostra PVC/PV/Pod e o marker persistente"
	@echo "  make storage-test-recreate Remove o Pod e valida persistência após recriação"
	@echo "  make storage-test-reprovision Recria o PVC descartável e valida o path atual"
	@echo "  make storage-test-delete   Remove workload e PVC de teste"
	@echo "  make backup-create         Cria backup local do datastore SQLite + token do K3s"
	@echo "  make backup-list           Lista backups locais e checksums do K3s"
	@echo "  make backup-verify         Reidrata e valida o backup mais recente sem tocar no K3s ativo"
	@echo "  make backup-install        Instala timer systemd, retenção local e sync R2 via Ansible"
	@echo "  make backup-status         Mostra timer e últimas execuções do backup"
	@echo "  make backup-run            Executa a cadeia completa e mostra evidência local/remota"
	@echo "  make backup-prune          Executa manualmente a retenção local configurada"
	@echo "  make backup-inventory      Inventaria PVCs/PVs e caminhos persistentes sem alterar dados"
	@echo "  make restic-test           Valida backup/restore restic em repositório temporário local"
	@echo "  make restic-r2-secret      Cria/atualiza credenciais R2 cifradas com SOPS"
	@echo "  make restic-r2-install     Instala credenciais R2 runtime em /etc/k3s-backup"
	@echo "  make restic-r2-test        Valida round-trip real Restic -> R2 -> restore"
	@echo "  make restic-r2-sync        Envia o backup K3s mais recente e aplica retenção remota"
	@echo "  make restic-r2-status      Lista o snapshot R2 mais recente"
	@echo "  make restic-r2-check       Executa restic check no repositório R2"
	@echo "  make firewall-audit        Audita firewall/listeners após K3s sem alterar regras"
	@echo "  make cluster-status        Mostra nodes, pods e services do cluster"
	@echo "  make lab-deploy            Cria namespace e workload de teste"
	@echo "  make lab-status            Mostra recursos do workload de teste"
	@echo "  make lab-test              Testa o Ingress localmente via Traefik"
	@echo "  make lab-delete            Remove o workload de teste"
	@echo "  make secrets-test          Valida round-trip SOPS + age sem persistir segredo"
	@echo "  make secret-edit FILE=...  Cria/edita Secret Kubernetes cifrado com SOPS"
	@echo "  make secret-view FILE=...  Mostra Secret descriptografado sem gravar plaintext"
	@echo "  make secret-validate FILE=... Valida manifest cifrado via kubectl dry-run"
	@echo "  make secret-apply FILE=... Aplica manifest cifrado sem gravar plaintext"
	@echo "  make tf-cloudflare-discovery Descobre IDs existentes sem imprimir tokens"
	@echo "  make tf-cloudflare-init    Inicializa provider Terraform da Cloudflare"
	@echo "  make tf-cloudflare-fmt     Valida formatação Terraform"
	@echo "  make tf-cloudflare-validate Valida configuração Terraform"
	@echo "  make tf-cloudflare-import  Importa recursos existentes para o state local"
	@echo "  make tf-cloudflare-plan    Mostra plano Cloudflare sem aplicar mudanças"
	@echo "  make tf-r2-init            Inicializa stack Terraform dedicada ao bucket R2"
	@echo "  make tf-r2-fmt             Valida formatação da stack R2"
	@echo "  make tf-r2-validate        Valida configuração Terraform do R2"
	@echo "  make tf-r2-plan            Mostra plano do bucket R2 sem aplicar mudanças"
	@echo "  make tf-r2-apply           Cria/atualiza o bucket R2 após revisão explícita do plano"

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

# Destructive only to the disposable lab/persistence-test PVC and its marker.
storage-test-reprovision:
	@echo "Reprovisioning disposable lab/persistence-test PVC; its test marker will be deleted."
	kubectl delete -f kubernetes/storage/persistence-test.yaml --ignore-not-found --wait=true
	kubectl apply -f kubernetes/storage/persistence-test.yaml
	kubectl rollout status deployment/persistence-test -n lab --timeout=120s
	@PV=$$(kubectl get pvc persistence-test -n lab -o jsonpath='{.spec.volumeName}'); \
	  PATH_VALUE=$$(kubectl get pv "$$PV" -o jsonpath='{.spec.hostPath.path}'); \
	  echo "Provisioned $$PV at $$PATH_VALUE"; \
	  case "$$PATH_VALUE" in \
	    /mnt/store1/k3s/local-path/*) echo "local-path placement OK" ;; \
	    *) echo "ERROR: expected path below /mnt/store1/k3s/local-path" >&2; exit 1 ;; \
	  esac
	$(MAKE) storage-test-status

storage-test-delete:
	kubectl delete -f kubernetes/storage/persistence-test.yaml --ignore-not-found

backup-create:
	sudo bash scripts/k3s-backup.sh

backup-list:
	sudo find /srv/k3s/backups/k3s -maxdepth 1 -type f \( -name 'k3s-*.tar.gz' -o -name 'k3s-*.tar.gz.sha256' \) -printf '%TY-%Tm-%Td %TH:%TM %10s %p\n' 2>/dev/null | sort || true

backup-verify:
	sudo bash scripts/k3s-backup-verify.sh $(if $(FILE),"$(FILE)",)

backup-install:
	cd ansible && ansible-playbook -K playbooks/backup.yml

backup-status:
	sudo systemctl status k3s-backup.timer --no-pager
	sudo systemctl list-timers k3s-backup.timer --no-pager
	@echo
	@echo "Últimas execuções:"
	sudo journalctl -u k3s-backup.service -n 60 --no-pager

backup-run:
	sudo systemctl start k3s-backup.service
	@echo
	@echo "== Backups locais =="
	$(MAKE) backup-list
	@echo
	@echo "== Última execução do serviço =="
	@sudo journalctl -u k3s-backup.service -n 40 --no-pager
	@echo
	@echo "== Snapshot off-host mais recente =="
	@$(MAKE) --no-print-directory restic-r2-status

backup-prune:
	sudo K3S_BACKUP_KEEP=$${K3S_BACKUP_KEEP:-14} bash scripts/k3s-backup-prune.sh

backup-inventory:
	bash scripts/k3s-persistence-inventory.sh

restic-test:
	sudo bash scripts/restic-smoke-test.sh

restic-r2-secret:
	bash scripts/restic-r2-secret.sh

restic-r2-install:
	bash scripts/restic-r2-install.sh

restic-r2-test:
	sudo bash scripts/restic-r2-test.sh

restic-r2-sync:
	sudo RESTIC_R2_KEEP_DAILY=$${RESTIC_R2_KEEP_DAILY:-14} \
	  RESTIC_R2_KEEP_WEEKLY=$${RESTIC_R2_KEEP_WEEKLY:-8} \
	  RESTIC_R2_KEEP_MONTHLY=$${RESTIC_R2_KEEP_MONTHLY:-12} \
	  bash scripts/restic-r2-sync.sh

restic-r2-status:
	@sudo bash -c 'set -euo pipefail; set -a; source /etc/k3s-backup/r2.env; set +a; export RESTIC_REPOSITORY_FILE=/etc/k3s-backup/restic.repository RESTIC_PASSWORD_FILE=/etc/k3s-backup/restic.password; restic snapshots --tag k3s-control-plane --latest 1'

restic-r2-check:
	@sudo bash -c 'set -euo pipefail; set -a; source /etc/k3s-backup/r2.env; set +a; export RESTIC_REPOSITORY_FILE=/etc/k3s-backup/restic.repository RESTIC_PASSWORD_FILE=/etc/k3s-backup/restic.password; restic check'

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

secrets-test:
	@set -euo pipefail; \
	TMPDIR=$$(mktemp -d); \
	trap 'rm -rf "$$TMPDIR"' EXIT; \
	PLAIN="$$TMPDIR/test.sops.yaml"; \
	ENC="$$TMPDIR/encrypted.sops.yaml"; \
	DEC="$$TMPDIR/decrypted.yaml"; \
	printf '%s\n' 'secret: sops-age-roundtrip-ok' > "$$PLAIN"; \
	sops --encrypt --config .sops.yaml "$$PLAIN" > "$$ENC"; \
	sops --decrypt "$$ENC" > "$$DEC"; \
	diff -u "$$PLAIN" "$$DEC"; \
	echo "SOPS + age round-trip OK"

secret-edit:
	@test -n "$(FILE)" || (echo "Use: make secret-edit FILE=kubernetes/secrets/name.sops.yaml" >&2; exit 2)
	bash scripts/sops-k8s-secret.sh edit "$(FILE)"

secret-view:
	@test -n "$(FILE)" || (echo "Use: make secret-view FILE=kubernetes/secrets/name.sops.yaml" >&2; exit 2)
	bash scripts/sops-k8s-secret.sh view "$(FILE)"

secret-validate:
	@test -n "$(FILE)" || (echo "Use: make secret-validate FILE=kubernetes/secrets/name.sops.yaml" >&2; exit 2)
	bash scripts/sops-k8s-secret.sh validate "$(FILE)"

secret-apply:
	@test -n "$(FILE)" || (echo "Use: make secret-apply FILE=kubernetes/secrets/name.sops.yaml" >&2; exit 2)
	bash scripts/sops-k8s-secret.sh apply "$(FILE)"

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

tf-r2-init:
	cd terraform/r2 && terraform init

tf-r2-fmt:
	cd terraform/r2 && terraform fmt -check -recursive

tf-r2-validate:
	cd terraform/r2 && terraform validate

tf-r2-plan:
	cd terraform/r2 && terraform plan

tf-r2-apply:
	cd terraform/r2 && terraform apply
