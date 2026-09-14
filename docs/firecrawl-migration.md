# Firecrawl — plano de migração Docker Compose -> K3s

## Estado atual

Firecrawl é o primeiro workload real escolhido para migração. O cutover para K3s foi concluído e a versão Kubernetes está atendendo o serviço, protegida por Cloudflare Access. O Docker Compose antigo está parado; seus containers e volumes permanecem preservados somente para rollback até o encerramento explícito da janela de observação.

Componentes observados no runtime Docker original:

| Componente | Imagem observada | Persistência Docker atual | Política K3s inicial |
|---|---|---|---|
| API | `ghcr.io/firecrawl/firecrawl` | nenhuma | stateless |
| Playwright | `ghcr.io/firecrawl/playwright-service:latest` | cache temporário | `emptyDir` em memória |
| Redis | `redis:alpine` | volume `firecrawl_redis-data` | efêmero via `emptyDir` |
| RabbitMQ | `rabbitmq:3-management` | volume Docker anônimo em `/var/lib/rabbitmq` | efêmero via `emptyDir` |
| PostgreSQL/NuQ | `ghcr.io/firecrawl/nuq-postgres:latest` | volume `firecrawl_nuq-postgres-data` | efêmero via `emptyDir` |

O stack Docker utilizava a rede privada `firecrawl_backend`. Somente a API era publicada no host, em `3002`.

Em 2026-09-14 a verificação explícita confirmou que nenhum container Firecrawl estava em execução. Os containers antigos permaneciam presentes em estado `Exited`, preservando um rollback simples. Quatro encerraram com código 0; o Playwright antigo permaneceu com `Exited (1)`, sem impacto no serviço atual porque o runtime Docker já não atende produção. Não executar `docker compose down -v` durante a janela de rollback.

## Auditoria runtime validada

A auditoria read-only confirmou os cinco containers esperados, limites e identidades imutáveis das imagens. Também identificou o volume Docker anônimo como pertencente ao RabbitMQ em `/var/lib/rabbitmq`.

As imagens do scaffold Kubernetes foram então pinadas pelos mesmos digests observados no runtime Docker:

- `ghcr.io/firecrawl/firecrawl@sha256:a88c2c1b546560b77206cf88da87600cb69ac65358eed1a0f8bb06dde691b065`;
- `ghcr.io/firecrawl/nuq-postgres@sha256:aed86f62858f29bd971abddcdeb301c12888098d2cf5d33c1ba42b053bc460f6`;
- `redis@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241`;
- `rabbitmq@sha256:e582c0bc7766f3342496d8485efb5a1df782b5ce3886ad017e2eaae442311f69`;
- `ghcr.io/firecrawl/playwright-service@sha256:468009bae00911d40d7120d58489a1d529362c22c45585cb9076094fe61b0025`.

Isso evita que uma atualização futura de `latest`, `alpine` ou tag implícita altere o staging de forma invisível.

## Decisão sobre persistência

Para esta primeira migração, PostgreSQL/NuQ, Redis e RabbitMQ foram explicitamente classificados como **efêmeros**.

Motivação:

- o objetivo atual é disponibilizar o Firecrawl como serviço utilizável, não preservar histórico interno de filas/jobs;
- esses componentes podem ser recriados junto com a aplicação;
- reduzir PVCs simplifica operação, backup e restore nesta fase;
- se surgir necessidade de preservar estado entre recriações de Pod, a decisão será revista.

Consequência importante: `emptyDir` sobrevive a restart do container dentro do mesmo Pod, mas é perdido quando o Pod é substituído/reagendado. Portanto, jobs em andamento e estado interno podem ser perdidos após recriação.

O perfil K3s atual **não contém PVCs do Firecrawl**.

## PVCs e uso de disco no laboratório

Para os workloads que usam `local-path`, o valor `requests.storage` de um PVC é capacidade declarada ao Kubernetes; no setup atual ele não pré-aloca nem reserva fisicamente todo aquele espaço em `/mnt/store1` e também não cria automaticamente uma quota rígida no ext4.

A implicação é que:

```text
capacidade nominal do PVC != espaço já ocupado/reservado no host
```

O consumo real cresce conforme arquivos são gravados. Isso permite overcommit e torna a monitoração do espaço livre de `/mnt/store1` mais importante que apenas somar capacidades declaradas. A explicação completa está em `docs/storage.md`.

## Publicação externa

A API é publicada em:

```text
https://firecrawl.guiosoft.info
```

O Ingress usa:

```yaml
ingressClassName: traefik
```

Fluxo validado:

```text
Internet
  ↓
Cloudflare Access
  ↓
Cloudflare *.guiosoft.info
  ↓
Tunnel atual no host
  ↓
127.0.0.1:80
  ↓
Traefik K3s
  ↓
Ingress firecrawl.guiosoft.info
  ↓
Service firecrawl-api:3002
  ↓
Pod firecrawl-api
```

Nenhum PostgreSQL, Redis, RabbitMQ ou Playwright é publicado externamente; todos permanecem acessíveis apenas por Services `ClusterIP`.

### Segurança da API pública

O Firecrawl continua com:

```text
USE_DB_AUTHENTICATION=false
```

Por isso a aplicação ainda pode registrar:

```text
You're bypassing authentication
```

Esse warning é esperado no perfil atual. A autenticação autoritativa foi deliberadamente movida para a borda Cloudflare, porque os consumidores são agentes máquina-a-máquina e não usuários humanos.

Foi criada por Terraform uma aplicação Cloudflare Access para `firecrawl.guiosoft.info` usando **Service Auth**. No provider/API da Cloudflare, essa ação é representada por:

```hcl
decision = "non_identity"
```

Foram criados dois Service Tokens independentes:

- `firecrawl-hermes`;
- `firecrawl-opencode`.

Cada agente usa os headers padrão:

```text
CF-Access-Client-Id
CF-Access-Client-Secret
```

O header `Authorization` fica livre para uma eventual autenticação nativa futura do Firecrawl.

O comportamento foi validado em runtime:

```text
sem Service Token -> HTTP 401
Hermes token      -> POST /v1/scrape com sucesso
OpenCode token    -> POST /v1/scrape com sucesso
```

O helper `scripts/firecrawl-access-test.sh` executa a validação sem imprimir credenciais. Os Client Secrets e o API Token Cloudflare nunca devem ser versionados; os secrets dos Service Tokens também existem no state local do Terraform, portanto esse state deve ser tratado como material sensível.

Durante a configuração houve dois problemas de autorização úteis para troubleshooting:

1. um API Token Cloudflare com validade incorreta retornou HTTP 401 durante o refresh de Tunnel/DNS;
2. depois de corrigida a validade, a ausência de `Access: Service Tokens Write` causou HTTP 403 `auth.forbidden` na criação dos Service Tokens.

A correção foi manter um token de IaC com escopo mínimo suficiente para Tunnel, DNS, Access Apps/Policies e Access Service Tokens.

## Recursos Kubernetes

Arquivos versionados:

```text
kubernetes/apps/firecrawl/
├── namespace.yaml
├── configmap.yaml
├── stack.yaml
├── ingress.yaml
├── secret.example.yaml
└── kustomization.yaml
```

O scaffold contém:

- namespace `firecrawl`;
- ConfigMap com configuração não sensível;
- Services `ClusterIP` para API, PostgreSQL, Redis, RabbitMQ e Playwright;
- Deployments para os cinco componentes;
- `emptyDir` para PostgreSQL, Redis e RabbitMQ;
- cache Playwright em `emptyDir` com `medium: Memory`;
- probes conservadoras;
- requests iniciais de CPU/memória e apenas limits de memória onde apropriado;
- imagens pinadas por digest;
- Ingress público `firecrawl.guiosoft.info`.

Hard CPU limits continuam evitados inicialmente para não introduzir throttling artificial sem evidência, seguindo a experiência observada com node-exporter na stack de monitoramento.

## Secrets

O Docker Compose usa `.env` com valores sensíveis. A regra permanece:

- não versionar `.env`;
- não copiar tokens/passwords para ConfigMap;
- armazenar o Secret Kubernetes real cifrado com SOPS + age;
- nunca imprimir os valores durante geração/aplicação.

Foi criado:

```bash
scripts/firecrawl-secret-from-env.sh
```

Uso:

```bash
bash scripts/firecrawl-secret-from-env.sh /caminho/do/firecrawl/.env
```

Saída padrão:

```text
kubernetes/apps/firecrawl/firecrawl-secrets.sops.yaml
```

O script:

1. lê o dotenv local sem executá-lo como shell;
2. seleciona somente as chaves usadas pelo Firecrawl;
3. cria o Secret em diretório temporário;
4. cifra imediatamente com SOPS + age;
5. remove o plaintext ao sair;
6. valida que o arquivo cifrado pode ser descriptografado;
7. não imprime valores secretos.

Fluxo já validado no cluster atual:

```bash
kubectl apply -f kubernetes/apps/firecrawl/namespace.yaml
make secret-validate FILE=kubernetes/apps/firecrawl/firecrawl-secrets.sops.yaml
make secret-apply FILE=kubernetes/apps/firecrawl/firecrawl-secrets.sops.yaml
```

O namespace `firecrawl` e o Secret `firecrawl-secrets` já foram criados/aplicados com sucesso sem expor seus valores em stdout.

O arquivo cifrado pode ser versionado; o `.env` e a identidade privada age não podem.

## Validação do scaffold

O comando:

```bash
make firecrawl-k8s-validate
```

é read-only e valida o perfil efetivo escolhido:

- Kustomize renderiza corretamente;
- `kubectl apply --dry-run=client` passa;
- existe Ingress para `firecrawl.guiosoft.info`;
- todas as imagens estão pinadas por digest;
- nenhum PVC Firecrawl é renderizado;
- PostgreSQL, Redis e RabbitMQ são tratados como efêmeros;
- o Secret runtime `firecrawl-secrets` é esperado separadamente.

Para consultar o estado depois do deploy:

```bash
make firecrawl-k8s-status
```

## Primeiro deploy K3s

O primeiro deploy real foi executado com sucesso. Os cinco Deployments ficaram `Ready`:

```text
nuq-postgres
redis
rabbitmq
playwright-service
firecrawl-api
```

O helper responsável é:

```bash
bash scripts/firecrawl-k8s.sh deploy
```

Ele verifica namespace e Secret antes de alterar recursos, executa novamente a validação do scaffold, aplica `kubectl apply -k kubernetes/apps/firecrawl` e aguarda o rollout dos cinco Deployments.

O deploy não altera automaticamente o Docker Compose antigo; o desligamento do runtime anterior foi feito somente depois das validações de tráfego, scrape e autenticação.

## Validação de tráfego e scrape funcional

O helper possui duas validações principais:

```bash
bash scripts/firecrawl-k8s.sh test
bash scripts/firecrawl-k8s.sh scrape-test
```

`test` não cria jobs. Ele confirma:

- todos os Deployments disponíveis;
- endpoint pronto no Service `firecrawl-api`;
- `GET /` local via Traefik usando `Host: firecrawl.guiosoft.info`;
- `GET /` público via Cloudflare Tunnel.

Esse caminho foi validado em runtime com HTTP 200 tanto localmente quanto via Cloudflare antes da ativação do Access. Após a ativação do Access, requests públicos sem Service Token passam a receber HTTP 401, como esperado.

`scrape-test` executa primeiro essa validação de caminho e, em seguida, envia um request real:

```http
POST /v1/scrape
Content-Type: application/json
```

O teste funcional real foi executado contra `https://www.guiosoft.info` e retornou:

```text
HTTP 200
success=true
markdown length=712
```

Portanto, o caminho completo aplicação -> fila/dependências -> scraping -> resposta HTTP foi validado com dados reais.

Baseline imediatamente após esse scrape:

```text
firecrawl-api       ~19m CPU   ~2826 MiB RAM
nuq-postgres        ~14m CPU   ~110 MiB RAM
playwright-service  ~48m CPU   ~268 MiB RAM
rabbitmq            ~197m CPU  ~224 MiB RAM
redis               ~5m CPU    ~9 MiB RAM
```

A API é claramente o maior consumidor de memória nesta amostra. A comparação com `docker stats` mostrou que esse perfil é compatível com o runtime Docker existente, no qual a API também é o maior consumidor e opera na faixa de múltiplos GiB com limite de 4 GiB. Portanto, não há evidência atual de overhead anormal introduzido pelo K3s.

## Observação de estabilidade

Foi adicionada uma ação read-only:

```bash
bash scripts/firecrawl-k8s.sh observe
```

Ela mostra:

- replicas desejadas/Ready/Available;
- status, idade e restart count dos Pods;
- consumo atual via `kubectl top`;
- eventos Kubernetes do tipo Warning;
- warnings/errors recentes de PostgreSQL, Redis, RabbitMQ, Playwright e API.

O comando não gera scrape, não reinicia recursos e não altera o Docker Compose.

Após o Compose ser parado, a observação de 2026-09-14 confirmou:

```text
firecrawl-api          Ready  RESTARTS=0  ~2903 MiB
nuq-postgres           Ready  RESTARTS=0  ~125 MiB
playwright-service     Ready  RESTARTS=0  ~278 MiB
rabbitmq               Ready  RESTARTS=0  ~355 MiB
redis                  Ready  RESTARTS=0  ~10 MiB
```

O consumo total observado ficou em aproximadamente 3,59 GiB de RAM e 207m de CPU. Não havia eventos Warning recentes. O warning do Playwright sobre ausência de proxy permanece esperado para o perfil atual, e o aviso de bypass de autenticação da API permanece esperado porque Cloudflare Access é a camada autoritativa.

Essa amostra, somada ao período anterior de funcionamento, foi considerada evidência suficiente para concluir a etapa de cutover e manter o Docker apenas como rollback preservado.

## Investigação dos restarts iniciais da API

A primeira observação mostrou dois restarts históricos do `firecrawl-api`. O estado anterior do container confirmou:

```text
reason: Error
exit code: 1
```

Não houve `OOMKilled`. O log anterior mostrou que um worker NuQ tentou conectar ao RabbitMQ em `:5672` antes de o broker estar aceitando conexões e recebeu `ECONNREFUSED`; o harness do Firecrawl encerrou o conjunto de processos e o Kubernetes reiniciou o container.

Isso caracteriza uma **corrida de inicialização entre Deployments**, não falta de memória nem falha persistente do Firecrawl. Readiness probes impedem tráfego para um Pod não pronto, mas não impõem ordem de startup entre Deployments independentes.

Para tornar o bootstrap determinístico, o Deployment `firecrawl-api` possui um `initContainer` que reutiliza a mesma imagem Firecrawl já pinada por digest e aguarda conectividade TCP com:

```text
nuq-postgres:5432
redis:6379
rabbitmq:5672
playwright-service:3000
```

Somente depois dessas dependências aceitarem conexão o container principal da API é iniciado. Não foi introduzida imagem auxiliar adicional nem tag flutuante.

A correção foi validada em runtime: após o redeploy, todos os Pods ficaram `Running/Ready` com `RESTARTS=0`. Houve apenas um evento transitório de `Startup probe failed` enquanto a API ainda abria a porta 3002; a probe tentou novamente e o container não reiniciou. Warnings de conexões TCP encerradas no RabbitMQ durante bootstrap e `AUTUMN_SECRET_KEY` ausente foram classificados como transitórios/opcionais para o perfil atual.

## Estratégia de implantação

Sequência atualizada:

1. auditar stack Docker atual — **concluído**;
2. identificar imagens/digests e volumes — **concluído**;
3. decidir persistência inicial — **concluído: PostgreSQL, Redis e RabbitMQ efêmeros**;
4. pin das imagens por digest — **concluído**;
5. criar Ingress `firecrawl.guiosoft.info` — **concluído**;
6. validar render/dry-run do scaffold no host — **concluído**;
7. gerar Secret SOPS a partir do `.env` local — **concluído**;
8. validar o Secret por dry-run — **concluído**;
9. criar namespace `firecrawl` — **concluído**;
10. aplicar o Secret cifrado via SOPS — **concluído**;
11. subir stack K3s — **concluído; cinco Deployments Ready**;
12. validar comunicação interna e readiness — **concluído**;
13. validar API localmente pelo Traefik usando Host header — **concluído**;
14. validar `https://firecrawl.guiosoft.info` via Cloudflare — **concluído**;
15. validar funcionalmente request real `/v1/scrape` — **concluído**;
16. investigar restarts iniciais — **concluído: corrida de startup com RabbitMQ, sem OOM**;
17. aplicar e validar `initContainer` de espera das dependências — **concluído; novo Pod com RESTARTS=0**;
18. definir autenticação da API — **concluído: Cloudflare Access Service Auth**;
19. criar Service Tokens por agente — **concluído: Hermes e OpenCode**;
20. validar bloqueio sem token e scrape autenticado — **concluído: 401 sem credencial e sucesso com ambos os tokens**;
21. parar o Docker Compose antigo mantendo possibilidade de rollback — **concluído**;
22. observar estabilidade e consumo com apenas o K3s atendendo o serviço — **concluído; cinco Pods Ready, zero restarts e sem warnings relevantes**;
23. remover Docker Compose somente após estabilidade suficiente — **pendente; manter containers e volumes durante a janela de rollback**.

Como não haverá migração de dados persistentes do Firecrawl nesta fase, o cutover ficou significativamente mais simples: não existe sincronização de banco antigo/novo nem risco de divergência de writes entre bancos.

## Estado pós-cutover

O serviço está operando exclusivamente pelo K3s. O runtime Docker antigo não está mais atendendo requisições, mas permanece materialmente disponível para rollback.

Critérios satisfeitos:

- cinco Deployments K3s Ready;
- Pods com `RESTARTS=0` na observação pós-cutover;
- scrape funcional real validado;
- dependências de startup estabilizadas com `initContainer`;
- API protegida por Cloudflare Access;
- HTTP 401 sem Service Token;
- Hermes e OpenCode autenticados com sucesso;
- nenhum evento Warning recente na amostra pós-cutover;
- perfil de recursos compatível com o baseline esperado;
- containers e volumes Docker antigos preservados.

A próxima ação relacionada ao Firecrawl é apenas a remoção definitiva do runtime antigo depois de uma janela de estabilidade suficientemente longa. Containers e volumes devem ser tratados separadamente; mesmo ao remover containers, os volumes não devem ser apagados automaticamente até confirmação explícita de que o rollback não é mais necessário.

## Rollback

Antes da remoção definitiva do Compose:

```text
K3s Firecrawl apresenta problema
        ↓
remover/desabilitar Ingress K3s se necessário
        ↓
reativar Docker Compose
        ↓
reativar endpoint Docker :3002 se necessário
```

Como o estado K3s atual é efêmero, não há necessidade de sincronizar dados de volta ao Compose.

## Fontes

- Firecrawl self-hosting: https://github.com/firecrawl/firecrawl/blob/main/SELF_HOST.md
- Firecrawl environment example: https://github.com/firecrawl/firecrawl/blob/main/apps/api/.env.example
- Cloudflare Access common policies: https://developers.cloudflare.com/cloudflare-one/access-controls/policies/common-policies/
- Cloudflare Access Service Tokens API: https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/service_tokens/
- Kubernetes `emptyDir`: https://kubernetes.io/docs/concepts/storage/volumes/#emptydir