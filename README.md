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

O layout persistente em `/srv/k3s` foi validado no host. Novos volumes do StorageClass `local-path` passam a ser provisionados em `/mnt/store1/k3s/local-path`, e existe um workload descartável para validar PVC, escrita e persistência após recriação do Pod.

A infraestrutura Cloudflare começou a ser declarada em Terraform usando o provider v5. O Tunnel existente, sua configuração remota e o wildcard DNS já possuem configuração declarativa, mas ainda devem ser importados para o state antes de qualquer `apply`.

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
make tf-cloudflare-init
make tf-cloudflare-validate
make tf-cloudflare-plan
```

O target `make storage` é conservador: valida que os discos esperados já estão montados, cria somente diretórios e links sob `/srv/k3s`, e não formata, reparticiona, move ou remove dados existentes.

O target `make k3s` também garante que novos volumes locais usem `/mnt/store1/k3s/local-path`. Para validar a persistência, `make storage-test` cria um PVC descartável e `make storage-test-recreate` recria o Pod mantendo o mesmo volume.

Para Cloudflare, o fluxo também é deliberadamente conservador: configurar variáveis locais, exportar `CLOUDFLARE_API_TOKEN`, importar os recursos existentes para o state e somente então revisar `terraform plan`. Não executar `apply` enquanto houver mudanças inesperadas.

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
- documentação oficial do K3s para `default-local-storage-path`;
- documentação do Rancher `local-path-provisioner` para comportamento de PVs locais;
- documentação oficial do Cloudflare Terraform Provider v5 para `cloudflare_dns_record`, `cloudflare_zero_trust_tunnel_cloudflared` e `cloudflare_zero_trust_tunnel_cloudflared_config`;
- documentação oficial da Cloudflare para importação de recursos existentes em Terraform;
- documentação versionada em `docs/current-state.md`, `docs/networking.md`, `docs/firewall.md`, `docs/storage.md` e `terraform/cloudflare/README.md`.

Nenhum dado persistente existente foi movido como parte da etapa de storage, e nenhum recurso Cloudflare deve ser recriado durante a adoção inicial de Terraform.
