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

O layout persistente em `/srv/k3s` foi validado no host. Novos volumes do StorageClass `local-path` são provisionados em `/mnt/store1/k3s/local-path`, e o workload descartável de persistência já confirmou que os dados sobrevivem à recriação do Pod.

A infraestrutura Cloudflare está declarada em Terraform usando o provider v5. O Tunnel existente, sua configuração remota e o wildcard DNS foram importados para o state local e o `terraform plan` foi validado com `No changes`.

SOPS + age estão instalados via Ansible. A identidade age é criada de forma idempotente somente quando ausente, a configuração pública do recipient está versionada em `.sops.yaml`, e o fluxo de encrypt/decrypt e de Kubernetes Secrets cifrados foi validado.

A base de backup do K3s também foi iniciada. O repositório inclui um script conservador para criar um backup local verificável do datastore SQLite e do server token em `/srv/k3s/backups/k3s`. O próximo passo é validar a criação no host e depois testar restore antes de habilitar agendamento e retenção automáticos.

## Divisão de responsabilidades

```text
Terraform
├── Cloudflare
│   ├── DNS
│   ├── Tunnel
│   └── rotas/public hostnames
└── infraestrutura externa futura

Ansible
├── preparação do Debian
├── instalação/configuração do K3s
├── diretórios e storage do host
├── ferramentas de IaC e secrets
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
│   ├── architecture.md
│   ├── backup.md
│   ├── current-state.md
│   ├── firewall.md
│   ├── migration.md
│   ├── networking.md
│   ├── roadmap.md
│   ├── secrets.md
│   ├── storage.md
│   └── troubleshooting.md
├── ansible/
├── terraform/
│   └── cloudflare/
├── kubernetes/
└── scripts/
```

## Operações principais

```bash
make preflight
make bootstrap
make storage
make k3s
make storage-test
make storage-test-recreate
make cluster-status
make firewall-audit
make secrets-test
make backup-create
make backup-list
make tf-cloudflare-init
make tf-cloudflare-validate
make tf-cloudflare-plan
```

O target `make storage` é conservador: valida que os discos esperados já estão montados, cria somente diretórios e links sob `/srv/k3s`, e não formata, reparticiona, move ou remove dados existentes.

O target `make k3s` também garante que novos volumes locais usem `/mnt/store1/k3s/local-path`. Para validar a persistência, `make storage-test` cria um PVC descartável e `make storage-test-recreate` recria o Pod mantendo o mesmo volume.

Secrets declarativos podem ser cifrados com SOPS + age. A chave privada age permanece fora do Git; somente o recipient público é versionado. O fluxo `secret-edit` / `secret-validate` / `secret-apply` permite manter Kubernetes Secrets cifrados em Git sem criar arquivos plaintext persistentes durante a aplicação.

Para Cloudflare, o fluxo também é deliberadamente conservador: configurar variáveis locais, exportar `CLOUDFLARE_API_TOKEN`, importar os recursos existentes para o state e revisar `terraform plan`. A adoção inicial foi concluída com zero drift e nenhum `apply` foi necessário.

O backup atual do K3s é local e intencionalmente simples. `make backup-create` cria um arquivo com o datastore SQLite e o server token e verifica tar + SHA-256. Esse arquivo contém material sensível e não deve ser versionado. Backup off-host e restore real ainda são obrigatórios antes de considerar a estratégia completa.

## Primeira etapa: discovery

Antes de instalar K3s, o estado atual do servidor foi inventariado. O script `scripts/discovery.sh` é somente leitura e coleta informações de sistema, rede, portas, serviços, containers, storage, firewall, bancos de dados e Cloudflare Tunnel, evitando deliberadamente coletar valores de secrets.

Execute no servidor:

```bash
sudo bash scripts/discovery.sh
```

O resultado será gravado em `discovery-output/` e deve ser revisado antes de ser versionado. Mesmo com redaction automática, não faça commit de um relatório sem inspeção manual.

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

## Princípio de disaster recovery

O objetivo operacional é que, em caso de perda do disco do sistema, seja possível reinstalar Debian e reconstruir o ambiente sem depender de configuração manual lembrada de cabeça.

Fluxo desejado:

```text
Debian limpo
   ↓
Ansible
   ↓
K3s
   ↓
bootstrap da infraestrutura do cluster
   ↓
GitOps
   ↓
aplicações
```

Dados persistentes como bancos de dados, uploads e repositórios não são reconstruíveis a partir do Git e deverão ter estratégia própria de backup/restore.

## Segurança

Este repositório é público. Nunca versionar:

- tokens do Cloudflare;
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

Os hostnames serão migrados progressivamente, mantendo rollback simples para os serviços antigos enquanto necessário.

## Fontes e evidências desta etapa

A evolução atual foi baseada em:

- discovery read-only executado no host Debian;
- estado observado dos mounts `/mnt/store1`, `/mnt/store2` e `/mnt/dev`;
- validações reais do cluster K3s, Traefik, Cloudflare Tunnel, `kubectl`, PVC/local-path e SOPS + age executadas no próprio servidor;
- documentação oficial do K3s para `default-local-storage-path`, datastore SQLite e backup/restore;
- documentação do Rancher `local-path-provisioner` para comportamento de PVs locais;
- documentação oficial do SOPS e age para recipients e gestão de secrets;
- documentação oficial do Cloudflare Terraform Provider v5 para `cloudflare_dns_record`, `cloudflare_zero_trust_tunnel_cloudflared` e `cloudflare_zero_trust_tunnel_cloudflared_config`;
- documentação oficial da Cloudflare para importação de recursos existentes em Terraform;
- documentação versionada em `docs/current-state.md`, `docs/networking.md`, `docs/firewall.md`, `docs/storage.md`, `docs/secrets.md`, `docs/backup.md` e `terraform/cloudflare/README.md`.

Nenhum dado persistente existente foi movido como parte da etapa de storage, nenhum recurso Cloudflare foi recriado durante a adoção inicial de Terraform e nenhum secret plaintext deve ser mantido no Git.
