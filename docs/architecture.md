# Arquitetura

## Contexto

O laboratório será implantado inicialmente em um único servidor físico Debian 13 que já executa serviços. A prioridade é aprender Kubernetes sem interromper o ambiente atual.

O cluster inicial será K3s single-node instalado diretamente no Debian. Serviços existentes permanecerão no host durante a transição.

## Arquitetura durante a migração

```text
                         ┌─────────────────────┐
Internet ── Cloudflare ──┤ Cloudflare Tunnel   │
                         └──────────┬──────────┘
                                    │
                       ┌────────────┴────────────┐
                       │ Debian 13 physical host │
                       │                         │
                       │ serviços legados       │
                       │ ├── app A : porta X    │
                       │ ├── app B : porta Y    │
                       │ └── ...                 │
                       │                         │
                       │ K3s                     │
                       │ ├── Traefik             │
                       │ ├── Services            │
                       │ └── workloads migrados │
                       └─────────────────────────┘
```

A rota Cloudflare de um hostname só será alterada quando o workload correspondente estiver validado no K3s.

## Arquitetura alvo

```text
Internet
   │
Cloudflare DNS / Zero Trust
   │
Cloudflare Tunnel (conexão outbound)
   │
cloudflared Deployment
   │
Traefik
   │
Kubernetes Services
   │
Pods
```

Manter Traefik mesmo sendo possível rotear `cloudflared` diretamente para Services é uma decisão deliberada: o laboratório deve permitir aprendizado de Ingress, middlewares, roteamento e load balancing Kubernetes, além de possibilitar acesso interno independente do Cloudflare no futuro.

## Infrastructure as Code

### Ansible

Responsável pelo estado do servidor existente:

- pacotes base;
- configuração necessária do Debian;
- diretórios e mounts;
- instalação/configuração K3s;
- firewall;
- bootstrap mínimo do cluster.

### Terraform

Responsável principalmente por recursos externos declarativos:

- Cloudflare Tunnel;
- DNS;
- public hostnames/routes;
- infraestrutura provisionável futura.

Não usaremos Terraform para instalar K3s no servidor físico.

### Kubernetes / Helm / GitOps

Responsáveis por recursos dentro do cluster:

- namespaces;
- cloudflared;
- ingress;
- observabilidade;
- aplicações;
- configuração declarativa dos workloads.

## Storage

Inicialmente será usado o `local-path` provisioner incluído no K3s para aprendizado de PVCs e workloads simples.

Dados persistentes serão tratados separadamente da configuração reconstruível. Estrutura conceitual do host:

```text
/srv/
├── k3s/
├── data/
│   ├── postgres/
│   ├── mongodb/
│   └── apps/
└── backup/
```

Os caminhos reais só serão definidos após o discovery do servidor. Automação nunca deverá apagar dados existentes durante bootstrap/rebuild.

## Secrets

Nenhum secret em texto puro será versionado. Estratégia prevista:

1. variáveis locais/Ansible Vault durante bootstrap inicial, quando necessário;
2. SOPS + age para secrets Kubernetes versionáveis de forma criptografada;
3. chaves de decriptação mantidas fora deste repositório.

## Evolução multi-node

O single-node é intencional. Um segundo nó será adicionado posteriormente para estudar:

- scheduling;
- nodeSelector e affinity;
- taints/tolerations;
- DaemonSets;
- cordon/drain;
- rescheduling;
- comportamento diante de falha de nó.

Duas réplicas de uma aplicação no mesmo nó aumentam tolerância a falha de processo/pod, mas não fornecem alta disponibilidade contra falha física do servidor.
