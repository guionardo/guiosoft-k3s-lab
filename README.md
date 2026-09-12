# guiosoft-k3s-lab

Laboratório pessoal para estudar Kubernetes com K3s em um servidor Debian 13 existente, migrando serviços gradualmente e mantendo toda a infraestrutura reproduzível.

## Objetivos

- instalar e operar um cluster K3s em hardware próprio;
- migrar serviços atuais sem big-bang;
- publicar aplicações por subdomínios de `guiosoft.info` usando Cloudflare Tunnel;
- aprender os principais conceitos de Kubernetes com workloads reais;
- manter infraestrutura e configuração em código;
- possibilitar reconstrução do ambiente após falha do disco do sistema;
- separar claramente infraestrutura reconstruível de dados persistentes.

## Arquitetura alvo

```text
Internet
   |
Cloudflare / guiosoft.info
   |
Cloudflare Tunnel
   |
K3s
  ├── cloudflared
  ├── Traefik
  ├── namespaces
  ├── workloads
  ├── observabilidade
  └── GitOps
```

Durante a migração, os serviços atuais continuarão rodando no host Debian. Cada serviço será movido individualmente para o K3s e o hostname correspondente será redirecionado apenas após validação.

## Estado atual

O cluster single-node K3s está operacional. Traefik, CoreDNS, metrics-server e local-path-provisioner estão funcionando, o acesso administrativo com `kubectl` já funciona sem `sudo`, e o caminho externo Cloudflare -> Tunnel -> Traefik -> Ingress -> Service -> Pod foi validado.

Hostnames desconhecidos sob o wildcard `*.guiosoft.info` chegam ao Traefik, mas recebem HTTP 404 quando não existe um Ingress explícito.

O layout persistente em `/srv/k3s` foi validado no host. Novos volumes `local-path` foram reprovisionados e confirmados fisicamente abaixo de `/mnt/store1/k3s/local-path`. O inventário read-only atual mostra apenas o PVC descartável `lab/persistence-test`; ainda não existe PVC real de aplicação.

A infraestrutura Cloudflare está declarada em Terraform usando o provider v5. O Tunnel existente, sua configuração remota e o wildcard DNS foram importados para o state local e o `terraform plan` foi validado com `No changes`.

SOPS + age estão instalados via Ansible. A identidade age é criada de forma idempotente somente quando ausente, a configuração pública do recipient está versionada em `.sops.yaml`, e o fluxo de encrypt/decrypt e de Kubernetes Secrets cifrados foi validado.

O backup do K3s foi validado manualmente, por restore rehearsal não destrutivo e pelo mesmo serviço usado no timer systemd. O timer diário, a retenção local e a cadeia automática de envio off-host estão operacionais.

A camada off-host usa Restic sobre Cloudflare R2. O bucket `guiosoft-k3s-backups` é gerenciado por uma stack Terraform separada, as credenciais runtime ficam cifradas com SOPS + age, o round-trip real Restic -> R2 -> restore foi validado por SHA-256 e o `k3s-backup.service` foi validado executando a cadeia completa local -> Restic -> R2 com `restic check` remoto.

A frente ativa é Disaster Recovery. O readiness check foi validado com sucesso e agora existe um rehearsal isolado que restaura o snapshot `k3s-control-plane` diretamente do R2 para staging temporário, validando archive, checksum, token e integridade SQLite sem escrever em `/var/lib/rancher/k3s` nem alterar o cluster ativo.

## Divisão de responsabilidades

```text
Terraform
├── Cloudflare
│   ├── DNS
│   ├── Tunnel
│   ├── rotas/public hostnames
│   └── bucket R2 de backup
└── infraestrutura externa futura

Ansible
├── preparação do Debian
├── instalação/configuração do K3s
├── diretórios e storage do host
├── ferramentas de IaC, secrets e backup
├── automação de backup local + off-host
├── firewall
└── bootstrap do cluster

Kubernetes / Helm / GitOps
├── cloudflared
├── Traefik
├── namespaces
├── observabilidade
└── aplicações
```

## Estrutura planejada

```text
.
├── README.md
├── Makefile
├── docs/
├── ansible/
├── terraform/
│   ├── cloudflare/
│   └── r2/
├── kubernetes/
├── secrets/
└── scripts/
```

## Operações principais

```bash
make preflight
make bootstrap
make tools
make storage
make k3s
make storage-test
make storage-test-recreate
make storage-test-placement
make cluster-status
make firewall-audit
make secrets-test
make backup-create
make backup-verify
make backup-install
make backup-status
make backup-run
make backup-inventory
make restic-r2-secret
make restic-r2-install
make restic-r2-test
make restic-r2-sync
make restic-r2-status
make restic-r2-check
make dr-readiness
make dr-r2-rehearsal
make tf-cloudflare-plan
make tf-r2-plan
```

O `Makefile` é a interface operacional preferida. Os scripts continuam sendo a implementação de baixo nível, mas operações normais do laboratório devem ser expostas por targets `make`.

O target `make storage` é conservador: valida que os discos esperados já estão montados, cria somente diretórios e links sob `/srv/k3s`, e não formata, reparticiona, move ou remove dados existentes.

O target `make k3s` garante que novos volumes locais usem `/mnt/store1/k3s/local-path`. Para validar persistência, `make storage-test` cria um PVC descartável e `make storage-test-recreate` recria apenas o Pod mantendo o mesmo volume. `make storage-test-placement` valida sem alterações que o PV atual está no disco esperado.

Secrets declarativos podem ser cifrados com SOPS + age. A chave privada age permanece fora do Git; somente o recipient público é versionado. Credenciais de infraestrutura, como as do Restic/R2, também são mantidas somente em arquivos `.sops.yaml` cifrados.

Para Cloudflare, o fluxo continua conservador: configurar variáveis locais, exportar tokens somente no ambiente, revisar `terraform plan` e aplicar explicitamente. DNS/Tunnel e R2 possuem stacks Terraform separadas por diferença de responsabilidade e permissões.

O backup completo do control plane segue:

```text
K3s SQLite + server token
        ↓
backup local + SHA-256
        ↓
retenção local
        ↓
Restic cifrado
        ↓
Cloudflare R2
        ↓
retenção daily/weekly/monthly pelo Restic
```

Para dados de aplicações, `make backup-inventory` é somente leitura e serve para identificar PVCs, PVs, caminhos físicos e Pods consumidores antes de definir backups. Como ainda não existem PVCs reais de aplicação, backups de bancos/PVCs serão implementados quando workloads stateful reais forem introduzidos.

## Disaster Recovery

O objetivo operacional é reconstruir o ambiente em outro host sem depender do disco raiz original:

```text
Debian limpo
   ↓
Git + Ansible
   ↓
restaurar identidade privada age
   ↓
SOPS recupera credenciais Restic/R2
   ↓
Restic recupera backup K3s do R2
   ↓
restaurar SQLite + server token
   ↓
K3s restaurado
```

Pré-validação:

```bash
make dr-readiness
```

Esse target é somente leitura e já foi validado no host atual.

A etapa seguinte é um restore ainda não destrutivo, mas usando o R2 como única fonte do artefato:

```bash
make dr-r2-rehearsal
```

Ele restaura o snapshot remoto para staging temporário isolado e reutiliza o verificador do backup para confirmar SHA-256, presença do server token, metadata SQLite e `PRAGMA integrity_check`. O staging é removido automaticamente e o K3s ativo não é alterado.

O restore destrutivo será implementado somente para um ambiente explicitamente separado de DR.

Detalhes em [`docs/disaster-recovery.md`](docs/disaster-recovery.md).

## Primeira etapa: discovery

Antes de instalar K3s, o estado atual do servidor foi inventariado. O script `scripts/discovery.sh` é somente leitura e coleta informações de sistema, rede, portas, serviços, containers, storage, firewall, bancos de dados e Cloudflare Tunnel, evitando deliberadamente coletar valores de secrets.

Execute no servidor:

```bash
sudo bash scripts/discovery.sh
```

O resultado será gravado em `discovery-output/` e deve ser revisado antes de ser versionado.

## Roadmap resumido

1. Discovery do Debian e serviços atuais
2. Estrutura de Infrastructure as Code
3. Instalação do K3s
4. Networking, Traefik e Cloudflare Tunnel
5. Migração gradual dos serviços
6. Persistência e backups
7. Observabilidade
8. GitOps
9. Disaster recovery testado
10. Segundo nó para cenários multi-node

Detalhes em [`docs/roadmap.md`](docs/roadmap.md).

## Segurança

Este repositório é público. Nunca versionar:

- tokens do Cloudflare;
- credenciais R2 em plaintext;
- senha do repositório Restic;
- kubeconfig real;
- chaves SSH ou identidade privada age;
- senhas;
- arquivos `.env` com credenciais;
- Secrets Kubernetes em texto puro;
- backups ou dumps de banco de dados;
- relatórios de discovery sem revisão.

SOPS + age são usados para secrets declarativos que precisam permanecer no Git. O recipient público pode ser versionado; a identidade privada permanece fora do repositório e precisa de cópia de recuperação off-host.

## Domínio

Domínio principal do laboratório: `guiosoft.info`.

## Fontes e evidências desta etapa

A evolução atual foi baseada em:

- discovery read-only executado no host Debian;
- validações reais do cluster K3s, Traefik, Cloudflare Tunnel, `kubectl`, PVC/local-path, SOPS + age e backup/restore executadas no próprio servidor;
- reprovisionamento controlado do PVC descartável e validação do novo path em `/mnt/store1/k3s/local-path`;
- validação do readiness check de disaster recovery no host atual;
- documentação oficial do K3s para `default-local-storage-path`, datastore SQLite e backup/restore;
- documentação do Rancher `local-path-provisioner`;
- documentação oficial do SOPS e age;
- documentação oficial do systemd para timers persistentes;
- documentação oficial do Restic para repositórios, S3-compatible backends, retenção, checks e restore;
- documentação oficial do Cloudflare R2 para API S3-compatible e API tokens;
- documentação oficial do Cloudflare Terraform Provider v5;
- documentação versionada em `docs/` e nas stacks `terraform/cloudflare/` e `terraform/r2/`.

Nenhum dado persistente existente foi movido como parte da etapa de storage e nenhum secret plaintext deve ser mantido no Git.
