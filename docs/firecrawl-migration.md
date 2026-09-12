# Firecrawl — plano de migração Docker Compose -> K3s

## Estado atual

Firecrawl continua sendo o primeiro workload real candidato à migração. Hoje ele roda em Docker Compose no host Debian e deve permanecer intacto até que a versão Kubernetes esteja validada.

Componentes observados no Compose atual:

| Componente | Imagem | Estado | Persistência atual | Observação |
|---|---|---|---|---|
| API | `ghcr.io/firecrawl/firecrawl` | stateless de aplicação | nenhuma | publica a porta 3002 no host |
| Playwright | `ghcr.io/firecrawl/playwright-service:latest` | stateless | tmpfs/cache efêmero | CPU/memória relativamente altos |
| Redis | `redis:alpine` | stateful | volume `redis-data` | filas/cache/estado runtime |
| RabbitMQ | `rabbitmq:3-management` | stateful operacional | volume Docker anônimo montado em `/var/lib/rabbitmq` | persiste estado entre recriações do container atual |
| PostgreSQL | `ghcr.io/firecrawl/nuq-postgres:latest` | stateful crítico | volume `nuq-postgres-data` | banco persistente principal |

O stack utiliza uma rede Docker privada `backend`. Somente a API é publicada no host; PostgreSQL, Redis, RabbitMQ e Playwright ficam internos.

## Auditoria runtime validada

A auditoria read-only executada no host confirmou os cinco containers esperados ativos há cerca de 12 dias:

- `firecrawl-api-1` em `ghcr.io/firecrawl/firecrawl`, publicando `3002:3002`;
- `firecrawl-nuq-postgres-1` em `ghcr.io/firecrawl/nuq-postgres:latest`;
- `firecrawl-redis-1` em `redis:alpine`;
- `firecrawl-rabbitmq-1` em `rabbitmq:3-management`, healthy;
- `firecrawl-playwright-service-1` em `ghcr.io/firecrawl/playwright-service:latest`.

Todos estão ligados somente à rede Docker `firecrawl_backend`, exceto pela publicação da API no host.

Os limites efetivos observados foram:

- API: `3 CPU / 4 GiB`;
- Playwright: `2 CPU / 3 GiB`;
- PostgreSQL, Redis e RabbitMQ: sem hard CPU/memory limit no Docker Compose atual.

### Identidade imutável das imagens observadas

O audit capturou os `repo_digest` efetivamente em execução e o scaffold K3s foi pinado para reproduzir exatamente esses artefatos durante o staging inicial:

```text
API        ghcr.io/firecrawl/firecrawl@sha256:a88c2c1b546560b77206cf88da87600cb69ac65358eed1a0f8bb06dde691b065
PostgreSQL ghcr.io/firecrawl/nuq-postgres@sha256:aed86f62858f29bd971abddcdeb301c12888098d2cf5d33c1ba42b053bc460f6
Redis      redis@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
RabbitMQ   rabbitmq@sha256:e582c0bc7766f3342496d8485efb5a1df782b5ce3886ad017e2eaae442311f69
Playwright ghcr.io/firecrawl/playwright-service@sha256:468009bae00911d40d7120d58489a1d529362c22c45585cb9076094fe61b0025
```

Isso evita que `latest`, `alpine` ou tags implícitas mudem silenciosamente entre o Docker atual e o staging K3s.

### Volumes observados

O volume anteriormente anônimo foi identificado sem ambiguidade:

```text
firecrawl-nuq-postgres-1
  /var/lib/docker/volumes/firecrawl_nuq-postgres-data/_data
  -> /var/lib/postgresql/data

firecrawl-redis-1
  /var/lib/docker/volumes/firecrawl_redis-data/_data
  -> /data

firecrawl-rabbitmq-1
  /var/lib/docker/volumes/ada1e8aec9043050844168d92f6f2d63b4ebfac26a20aacd4dfe45e48fa454fe/_data
  -> /var/lib/rabbitmq
```

Portanto, embora o `docker-compose.yml` não declare um volume nomeado para RabbitMQ, a imagem criou/usa armazenamento Docker persistente em `/var/lib/rabbitmq`. Isso muda a classificação do componente: o conteúdo continua sendo operacional/in-flight, mas a implantação K3s deve preservar seu filesystem entre reinícios de Pod. O scaffold agora possui PVC `rabbitmq-data` dedicado.

Nenhum dado ou environment secret foi alterado ou impresso pela auditoria.

## Recursos atuais declarados

- API: até 3 CPUs / 4 GiB;
- Playwright: até 2 CPUs / 3 GiB;
- demais serviços sem hard limit explícito no Compose;
- concorrência configurada para perfil de homelab, incluindo workers, jobs, browser pool e requests simultâneos.

Esses valores são limites máximos do runtime atual e **não devem ser simplesmente copiados para requests Kubernetes**. O scaffold K3s usa requests menores e, por padrão, evita hard CPU limits; memória continua limitada para reduzir risco de um workload degradar todo o single-node.

## Secrets

O Compose injeta múltiplas variáveis via `.env`, incluindo chaves de API, credenciais de banco, proxy e integrações externas.

Regras para a migração:

- não versionar `.env`;
- não copiar secrets para ConfigMap;
- criar Secret Kubernetes cifrado com SOPS + age;
- separar configuração não sensível em ConfigMap;
- manter passwords/tokens fora de logs e scripts de auditoria;
- aplicar least privilege: Playwright recebe apenas credenciais de proxy opcionais, e não credenciais de PostgreSQL ou integrações que não utiliza.

O template público `kubernetes/apps/firecrawl/secret.example.yaml` contém apenas placeholders. O Secret real esperado pelo runtime chama-se `firecrawl-secrets` e deve ser criado como arquivo `*.sops.yaml` cifrado antes de qualquer deploy real.

## Persistência

### PostgreSQL

`nuq-postgres-data` é o dado crítico da aplicação.

A migração não deve copiar diretamente o diretório físico do volume Docker para um PVC PostgreSQL em execução. O caminho preferido será backup lógico/dump + restore em uma instância PostgreSQL nova dentro do K3s, seguido de validação.

A documentação atual do Firecrawl confirma que o NuQ/PostgreSQL é a fonte de estado da fila e que a imagem `nuq-postgres` possui requisitos próprios, incluindo `pg_cron`. Por isso a migração preserva essa imagem em vez de substituir o banco por um PostgreSQL genérico sem validar compatibilidade.

### Redis

`redis-data` existe como named volume. Antes de decidir migrá-lo, precisamos determinar se o conteúdo é necessário para continuidade de jobs ou se pode ser tratado como estado transitório/cache. O scaffold inicial mantém um PVC dedicado para permitir teste conservador sem assumir que o volume pode ser descartado.

### RabbitMQ

A auditoria mostrou que RabbitMQ **possui estado persistido no Docker atual**, apesar de o Compose não declarar um volume explicitamente. O volume anônimo está montado em `/var/lib/rabbitmq`.

Isso não muda a interpretação de negócio: RabbitMQ continua sendo transporte operacional e jobs em trânsito devem ser drenados/evitados no cutover. Porém, para equivalência operacional e para não perder fila/configuração em uma simples recriação de Pod, o scaffold K3s agora usa PVC `rabbitmq-data` de 2 GiB e `strategy: Recreate`.

Não vamos copiar o diretório físico do volume Docker para o PVC Kubernetes. Antes do cutover será decidido se a fila deve ser drenada e recriada vazia ou se algum procedimento de migração/export é necessário.

## Arquitetura Kubernetes proposta

Primeira versão:

```text
Cloudflare Tunnel no host
        |
        v
Traefik Ingress       <- somente após validação/autenticação
        |
        v
firecrawl-api Service
        |
        +--> Redis Service + PVC
        +--> RabbitMQ Service + PVC
        +--> PostgreSQL Service + PVC
        +--> Playwright Service
```

Todos os backends continuam `ClusterIP`. O scaffold base **não contém Ingress público**. Isso é intencional porque o Firecrawl self-hosted pode operar sem autenticação de API; não vamos publicar uma instância de staging antes de definir explicitamente o controle de acesso.

Namespace: `firecrawl`.

A migração do `cloudflared` para dentro do cluster continua fora deste passo.

## Scaffold Kubernetes criado

Arquivos versionados:

```text
kubernetes/apps/firecrawl/
├── namespace.yaml
├── configmap.yaml
├── stack.yaml
├── secret.example.yaml
└── kustomization.yaml
```

O scaffold contém:

- namespace isolado `firecrawl`;
- ConfigMap apenas com configuração não sensível;
- PVC PostgreSQL de 10 GiB em `local-path`;
- PVC Redis de 2 GiB em `local-path`;
- PVC RabbitMQ de 2 GiB em `local-path`;
- Services `ClusterIP` para API, PostgreSQL, Redis, RabbitMQ e Playwright;
- Deployments de cada componente;
- probes conservadoras usando `pg_isready`, `redis-cli`, `rabbitmq-diagnostics` e TCP para API/Playwright enquanto não definimos um health endpoint HTTP estável;
- `strategy: Recreate` nos componentes que usam PVC local;
- requests conservadores e limites de memória; hard CPU limits foram evitados inicialmente para não introduzir throttling artificial sem evidência;
- imagens pinadas pelos digests exatamente observados no Docker atual;
- nenhum Ingress na base.

## Validação do scaffold

Foi adicionado:

```bash
bash scripts/firecrawl-k8s.sh validate
```

O comando é read-only e:

- renderiza o Kustomize;
- executa `kubectl apply --dry-run=client`;
- confirma que não há Ingress público na base;
- lista imagens;
- destaca referências flutuantes que precisam ser pinadas antes de produção;
- lista PVCs;
- documenta a expectativa do Secret SOPS.

Para consultar estado futuro sem alterar recursos:

```bash
bash scripts/firecrawl-k8s.sh status
```

## Estratégia de implantação

Não faremos cutover direto do Docker Compose para Kubernetes.

Sequência prevista:

1. executar auditoria read-only do stack Docker atual; **concluído**;
2. confirmar imagens efetivas, volumes, limites, portas e consumo; **quase concluído** — identidade imutável e mounts já confirmados, falta medir uso dos volumes;
3. identificar health endpoint da API e dependências de startup;
4. validar sintaxe/renderização do scaffold Kubernetes sem aplicar recursos;
5. criar Secret SOPS real a partir do `.env`, sem expor valores;
6. pin das imagens Firecrawl compatíveis; **concluído para o staging inicial usando os digests em execução**;
7. iniciar stack Kubernetes com dados descartáveis primeiro;
8. validar comunicação interna e health checks;
9. definir autenticação e só então publicar hostname temporário via Traefik/Cloudflare wildcard;
10. validar logs no Loki e, quando expostas, métricas no Prometheus;
11. gerar backup consistente do PostgreSQL Docker;
12. impedir novas escritas/jobs durante a janela de cutover;
13. restaurar dados na instância K3s;
14. validar funcionalmente a aplicação;
15. mudar o hostname definitivo para o Ingress Kubernetes;
16. manter Docker Compose parado, mas disponível para rollback por uma janela curta;
17. remover stack antigo somente depois de estabilidade e backup/restore confirmados.

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
- imagens efetivas e identidade imutável (`image_id` / `repo_digest`);
- estado e portas;
- CPU/memória/restart policy;
- volumes, mountpoints e destination dentro de cada container;
- redes;
- portas publicadas no host.

Ele não imprime environment variables nem altera Docker/Kubernetes.

## Critérios antes do primeiro deploy K3s

Antes de criar uma instância de staging real precisamos confirmar:

- o `kubectl kustomize` e dry-run do scaffold passam;
- digests das imagens de staging estão pinados; **concluído**;
- Secret SOPS real existe sem plaintext no Git;
- endpoint/semântica de health da API são conhecidos ou a probe TCP inicial foi explicitamente aceita;
- tamanho/uso atual dos volumes cabe nos PVCs propostos;
- volume Docker anônimo é associado ao container/destination correto; **concluído: RabbitMQ -> `/var/lib/rabbitmq`**;
- política para Redis durante migração é decidida;
- política de fila RabbitMQ no cutover é decidida;
- procedimento de dump/restore do `nuq-postgres` é ensaiado.

## Decisões atuais

- Firecrawl será migrado como **primeiro workload real**, mas de modo conservador;
- não mover volumes físicos às cegas;
- PostgreSQL é estado crítico e terá migração explícita por backup/restore;
- Redis precisa ser classificado antes do cutover;
- RabbitMQ possui persistência operacional no runtime atual e terá PVC no K3s, mas não será tratado como fonte autoritativa de negócio;
- staging usa exatamente os digests observados no Docker atual;
- secrets serão SOPS + age;
- Cloudflare Tunnel permanece no host neste passo;
- nenhum Ingress público será aplicado antes de uma decisão explícita de autenticação/acesso;
- Docker Compose permanece disponível para rollback até conclusão da validação.

## Fontes

- Firecrawl, guia oficial de self-hosting: https://github.com/firecrawl/firecrawl/blob/main/SELF_HOST.md
- Firecrawl, configuração atual de ambiente da API: https://github.com/firecrawl/firecrawl/blob/main/apps/api/.env.example
- Firecrawl upstream: https://github.com/firecrawl/firecrawl

Pontos extraídos dessas fontes para esta etapa: preferência por release/tag exata em vez de referências flutuantes; NuQ PostgreSQL como backend de fila; API self-hosted potencialmente sem autenticação por padrão; dependências internas não devem ser publicadas; persistência e recuperação são responsabilidade de quem opera a instalação self-hosted.
