# Firecrawl — plano de migração Docker Compose -> K3s

## Estado atual

Firecrawl continua sendo o primeiro workload real candidato à migração. Hoje ele roda em Docker Compose no host Debian e deve permanecer intacto até que a versão Kubernetes esteja validada.

Componentes observados no Compose atual:

| Componente | Imagem | Estado | Persistência atual | Observação |
|---|---|---|---|---|
| API | `ghcr.io/firecrawl/firecrawl` | stateless de aplicação | nenhuma | publica a porta 3002 no host |
| Playwright | `ghcr.io/firecrawl/playwright-service:latest` | stateless | tmpfs/cache efêmero | CPU/memória relativamente altos |
| Redis | `redis:alpine` | stateful | volume `redis-data` | filas/cache/estado runtime |
| RabbitMQ | `rabbitmq:3-management` | stateful operacional | sem volume explícito no Compose atual | pode conter mensagens em trânsito, mas não é tratado como armazenamento durável |
| PostgreSQL | `ghcr.io/firecrawl/nuq-postgres:latest` | stateful crítico | volume `nuq-postgres-data` | banco persistente principal |

O stack utiliza uma rede Docker privada `backend`. Somente a API é publicada no host; PostgreSQL, Redis, RabbitMQ e Playwright ficam internos.

## Recursos atuais declarados

- API: até 3 CPUs / 4 GiB;
- Playwright: até 2 CPUs / 3 GiB;
- demais serviços sem hard limit explícito no Compose;
- concorrência configurada para perfil de homelab, incluindo workers, jobs, browser pool e requests simultâneos.

Esses valores são limites máximos do runtime atual e **não devem ser simplesmente copiados para requests Kubernetes**. Antes do deploy K3s vamos usar consumo real para definir requests conservadores e limits apenas onde fizer sentido.

## Secrets

O Compose injeta múltiplas variáveis via `.env`, incluindo chaves de API, credenciais de banco, proxy e integrações externas.

Regras para a migração:

- não versionar `.env`;
- não copiar secrets para ConfigMap;
- criar Secret Kubernetes cifrado com SOPS + age;
- separar configuração não sensível em ConfigMap;
- manter passwords/tokens fora de logs e scripts de auditoria.

## Persistência

### PostgreSQL

`nuq-postgres-data` é o dado crítico da aplicação.

A migração não deve copiar diretamente o diretório físico do volume Docker para um PVC PostgreSQL em execução. O caminho preferido será backup lógico/dump + restore em uma instância PostgreSQL nova dentro do K3s, seguido de validação.

### Redis

`redis-data` existe como named volume. Antes de decidir migrá-lo, precisamos determinar se o conteúdo é necessário para continuidade de jobs ou se pode ser tratado como estado transitório/cache.

### RabbitMQ

O Compose atual não declara volume persistente para RabbitMQ. Portanto, o objetivo da migração não é preservar seu filesystem atual; o ponto importante é drenar/evitar jobs em trânsito durante o cutover.

## Arquitetura Kubernetes proposta

Primeira versão:

```text
Cloudflare Tunnel no host
        |
        v
Traefik Ingress
        |
        v
firecrawl-api Service
        |
        +--> Redis Service
        +--> RabbitMQ Service
        +--> PostgreSQL Service + PVC
        +--> Playwright Service
```

Todos os backends continuam `ClusterIP`. Apenas a API recebe Ingress.

Namespace proposto: `firecrawl`.

A migração do `cloudflared` para dentro do cluster continua fora deste passo.

## Estratégia de implantação

Não faremos cutover direto do Docker Compose para Kubernetes.

Sequência prevista:

1. executar auditoria read-only do stack Docker atual;
2. confirmar imagens efetivas, volumes, limites, portas e consumo;
3. identificar health endpoint da API e dependências de startup;
4. criar namespace, ConfigMap, Secret SOPS e manifests Kubernetes;
5. criar PVC PostgreSQL e, se necessário, PVC Redis;
6. iniciar stack Kubernetes com dados descartáveis primeiro;
7. validar comunicação interna e health checks;
8. publicar hostname temporário via Traefik/Cloudflare wildcard;
9. validar logs no Loki e, quando expostas, métricas no Prometheus;
10. gerar backup consistente do PostgreSQL Docker;
11. impedir novas escritas/jobs durante a janela de cutover;
12. restaurar dados na instância K3s;
13. validar funcionalmente a aplicação;
14. mudar o hostname definitivo para o Ingress Kubernetes;
15. manter Docker Compose parado, mas disponível para rollback por uma janela curta;
16. remover stack antigo somente depois de estabilidade e backup/restore confirmados.

## Rollback

Enquanto a migração não estiver considerada estável:

```text
K3s Firecrawl apresenta problema
        |
        +--> interromper writes na versão K3s
        +--> restaurar rota para o endpoint antigo
        +--> subir novamente Docker Compose
```

Rollback com banco exige atenção: depois que o K3s aceitar escrita real, não existe rollback seguro para o banco antigo sem sincronização/restauração. Por isso o ponto de corte precisa ser explícito.

## Auditoria do runtime atual

Foi adicionado o script:

```bash
bash scripts/firecrawl-migration-audit.sh
```

Ele é read-only e coleta somente metadados não secretos:

- containers do projeto Compose `firecrawl`;
- imagens efetivas;
- estado e portas;
- CPU/memória/restart policy;
- named volumes e mountpoints;
- redes;
- portas publicadas no host.

Ele não imprime environment variables nem altera Docker/Kubernetes.

## Critérios para iniciar manifests

Antes de criar o deployment definitivo precisamos confirmar em runtime:

- os cinco containers esperados estão ativos;
- volume PostgreSQL efetivo;
- volume Redis efetivo;
- imagens/digests efetivos em produção;
- endpoint/semântica de health da API;
- consumo normal e em carga de API e Playwright;
- política desejada para Redis durante migração;
- procedimento de dump/restore do `nuq-postgres`.

## Decisões atuais

- Firecrawl será migrado como **primeiro workload real**, mas de modo conservador;
- não mover volumes físicos às cegas;
- PostgreSQL é estado crítico e terá migração explícita por backup/restore;
- Redis precisa ser classificado antes do cutover;
- RabbitMQ será tratado como estado operacional/in-flight, não como armazenamento durável no desenho atual;
- secrets serão SOPS + age;
- Cloudflare Tunnel permanece no host neste passo;
- Docker Compose permanece disponível para rollback até conclusão da validação.
