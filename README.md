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

A etapa atual prepara o storage de forma não destrutiva. O layout lógico usa `/srv/k3s`, mantendo os dados físicos nos mounts existentes e sem alterar ainda o StorageClass do K3s.

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
│   ├── current-state.md
│   ├── firewall.md
│   ├── migration.md
│   ├── networking.md
│   ├── roadmap.md
│   ├── storage.md
│   └── troubleshooting.md
├── ansible/
├── terraform/
├── kubernetes/
└── scripts/
```

## Operações principais

```bash
make preflight
make bootstrap
make k3s
make storage
make cluster-status
make firewall-audit
```

O target `make storage` é conservador: valida que os discos esperados já estão montados, cria somente diretórios e links sob `/srv/k3s`, e não formata, reparticiona, move ou remove dados existentes.

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
- chaves SSH ou age;
- senhas;
- arquivos `.env` com credenciais;
- Secrets Kubernetes em texto puro;
- backups ou dumps de banco de dados;
- relatórios de discovery sem revisão.

A estratégia prevista é começar simples e evoluir para SOPS + age para secrets declarativos no Kubernetes.

## Domínio

Domínio principal do laboratório: `guiosoft.info`.

Os hostnames serão migrados progressivamente, mantendo rollback simples para os serviços antigos enquanto necessário.

## Fontes e evidências desta etapa

A evolução atual foi baseada em:

- discovery read-only executado no host Debian;
- estado observado dos mounts `/mnt/store1`, `/mnt/store2` e `/mnt/dev`;
- validações reais do cluster K3s, Traefik, Cloudflare Tunnel e `kubectl` executadas no próprio servidor;
- documentação versionada em `docs/current-state.md`, `docs/networking.md`, `docs/firewall.md` e `docs/storage.md`.

Nenhum dado persistente foi movido como parte desta etapa de storage.
