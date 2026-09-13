# Firecrawl — plano de migração Docker Compose -> K3s

## Estado atual

Firecrawl é o primeiro workload real escolhido para migração. Hoje ele roda em Docker Compose no host Debian e deve permanecer disponível até que a versão Kubernetes esteja validada.

Componentes observados no runtime atual:

| Componente | Imagem observada | Persistência Docker atual | Política K3s inicial |
|---|---|---|---|
| API | `ghcr.io/firecrawl/firecrawl` | nenhuma | stateless |
| Playwright | `ghcr.io/firecrawl/playwright-service:latest` | cache temporário | `emptyDir` em memória |
| Redis | `redis:alpine` | volume `firecrawl_redis-data` | efêmero via `emptyDir` |
| RabbitMQ | `rabbitmq:3-management` | volume Docker anônimo em `/var/lib/rabbitmq` | efêmero via `emptyDir` |
| PostgreSQL/NuQ | `ghcr.io/firecrawl/nuq-postgres:latest` | volume `firecrawl_nuq-postgres-data` | efêmero via `emptyDir` |

O stack utiliza a rede Docker privada `firecrawl_backend`. Somente a API é publicada atualmente no host, em `3002`.

## Auditoria runtime validada

A auditoria read-only confirmou os cinco containers esperados ativos, limites atuais e identidades imutáveis das imagens. Também identificou o volume Docker anônimo como pertencente ao RabbitMQ em `/var/lib/rabbitmq`.

As imagens do scaffold Kubernetes foram então pinadas pelos mesmos digests observados no runtime Docker atual:

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

Foi aprovada a publicação direta da API em:

```text
https://firecrawl.guiosoft.info
```

O Ingress usa:

```yaml
ingressClassName: traefik
```

Fluxo esperado:

```text
Internet
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

O Ingress não adiciona autenticação por si só. Se a API Firecrawl em execução não exigir credencial de cliente, `firecrawl.guiosoft.info` será utilizável por qualquer pessoa que conheça o endpoint, podendo consumir CPU, memória e integrações externas configuradas.

A publicação pública foi aceita para este ambiente, mas autenticação/rate limiting via aplicação ou Cloudflare continua sendo uma opção futura se o uso anônimo não for desejado.

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

O Docker Compose atual não é parado nem alterado por esse deploy e continua disponível como rollback.

## Validação de tráfego e scrape funcional

O helper possui duas validações separadas:

```bash
bash scripts/firecrawl-k8s.sh test
bash scripts/firecrawl-k8s.sh scrape-test
```

`test` não cria jobs. Ele confirma:

- todos os Deployments disponíveis;
- endpoint pronto no Service `firecrawl-api`;
- `GET /` local via Traefik usando `Host: firecrawl.guiosoft.info`;
- `GET /` público via Cloudflare Tunnel.

`scrape-test` executa primeiro essa validação de caminho e, em seguida, envia um request real:

```http
POST /v1/scrape
Content-Type: application/json
```

Payload padrão:

```json
{
  "url": "https://example.com",
  "formats": ["markdown"]
}
```

O teste exige HTTP 200, `success=true` e conteúdo Markdown não vazio. Ao final também mostra `kubectl top pods` quando o metrics-server possui dados e exibe somente warnings/errors recentes da API para facilitar troubleshooting.

É possível trocar o alvo sem editar o script:

```bash
FIRECRAWL_SCRAPE_URL=https://www.example.org bash scripts/firecrawl-k8s.sh scrape-test
```

Nenhum Secret é exibido e o Docker Compose antigo permanece intocado.

## Estratégia de implantação

Sequência atualizada:

1. auditar stack Docker atual — **concluído**;
2. identificar imagens/digests e volumes — **concluído**;
3. decidir persistência inicial — **concluído: PostgreSQL, Redis e RabbitMQ efêmeros**;
4. pin das imagens por digest — **concluído**;
5. criar Ingress `firecrawl.guiosoft.info` — **concluído em código**;
6. validar render/dry-run do scaffold no host — **concluído**;
7. gerar Secret SOPS a partir do `.env` local — **concluído**;
8. validar o Secret por dry-run — **concluído**;
9. criar namespace `firecrawl` — **concluído**;
10. aplicar o Secret cifrado via SOPS — **concluído**;
11. subir stack K3s — **concluído; cinco Deployments Ready**;
12. validar comunicação interna e readiness — **concluído no rollout**;
13. validar API localmente pelo Traefik usando Host header — **próximo teste**;
14. validar `https://firecrawl.guiosoft.info` via Cloudflare — **próximo teste**;
15. validar funcionalmente request real `/v1/scrape` — **logo depois do teste de rota**;
16. observar logs e consumo de recursos;
17. parar o Docker Compose antigo após período de confiança;
18. manter rollback simples enquanto a nova instalação estiver em observação.

Como não haverá migração de dados persistentes do Firecrawl nesta fase, o cutover fica significativamente mais simples: não existe sincronização de banco antigo/novo nem risco de divergência de writes entre bancos.

## Rollback

Antes da remoção definitiva do Compose:

```text
K3s Firecrawl apresenta problema
        ↓
remover/desabilitar Ingress K3s se necessário
        ↓
parar stack K3s
        ↓
reativar endpoint Docker :3002
```

Como o estado K3s atual é efêmero, não há necessidade de sincronizar dados de volta ao Compose.

## Fontes

- Firecrawl self-hosting: https://github.com/firecrawl/firecrawl/blob/main/SELF_HOST.md
- Firecrawl environment example: https://github.com/firecrawl/firecrawl/blob/main/apps/api/.env.example
- Firecrawl upstream: https://github.com/firecrawl/firecrawl
- Firecrawl scrape endpoint examples in upstream repository: `POST /v1/scrape` with JSON payload containing `url` and `formats`
- Kubernetes `emptyDir`: https://kubernetes.io/docs/concepts/storage/volumes/#emptydir
- K3s storage: https://docs.k3s.io/add-ons/storage
