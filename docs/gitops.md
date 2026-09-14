# GitOps com Flux

## Decisão

A Fase 7 adotou **Flux** como controlador GitOps do cluster.

A escolha foi feita principalmente por aderência ao estado atual do projeto:

- o repositório já contém manifests Kubernetes e configurações Helm versionadas;
- SOPS + age já é o padrão de secrets do laboratório;
- o `kustomize-controller` do Flux possui decriptação SOPS nativa;
- o bootstrap oficial grava os manifests do próprio Flux no repositório e depois os reconcilia a partir do Git;
- não precisamos introduzir uma UI/CD server adicional somente para operar o laboratório;
- o modelo pull-based combina com o objetivo de reconstrução declarativa do cluster.

Argo CD continua sendo uma alternativa válida, especialmente quando UI, catálogo de Applications e fluxos operacionais visuais forem prioridade. Para este cluster, porém, o suporte SOPS nativo do Flux reduz componentes e customizações.

## Versão inicial

Versão de referência escolhida em 2026-09-14:

```text
Flux v2.9.5
```

A versão está pinada na automação de instalação.

## Layout GitOps atual

O bootstrap usa:

```text
clusters/
└── guiosoft-info/
    ├── flux-system/
    ├── cloudflare-namespace.yaml
    ├── cloudflare-secrets.yaml
    ├── cloudflared.yaml
    ├── firecrawl-namespace.yaml
    ├── firecrawl-secrets.yaml
    ├── firecrawl.yaml
    ├── monitoring-namespace.yaml
    ├── observability-helm.yaml
    └── kustomization.yaml
```

Namespaces, secrets e workloads são reconciliados em escopos separados. Os secrets cifrados também são separados por aplicação sob `kubernetes/secrets/<app>/`, evitando que uma Kustomization assuma secrets de outro namespace.

## Bootstrap GitHub

O repositório é:

```text
guionardo/guiosoft-k3s-lab
```

O bootstrap foi executado com chave SSH/deploy key para o acesso runtime do Flux ao GitHub:

```bash
flux check --pre

flux bootstrap github \
  --owner=guionardo \
  --repository=guiosoft-k3s-lab \
  --branch=main \
  --path=clusters/guiosoft-info \
  --personal \
  --token-auth=false
```

Um GitHub token/PAT foi necessário apenas para a operação de bootstrap no GitHub. Com `--token-auth=false`, o acesso runtime do Flux ao repositório usa SSH/deploy key em vez de manter o PAT como credencial Git do cluster.

## Primeira adoção: cloudflared

O `cloudflared` foi escolhido como primeiro workload real sob Flux por ser pequeno, stateless, declarativo e possuir rollback simples.

A ordem de reconciliação é:

```text
cloudflare-namespace
        ↓
cloudflare-secrets
        ↓
cloudflared
```

A adoção foi validada com recuperação do Secret SOPS, drift manual de réplicas, mudança versionada e rollback via Git, mantendo a rota pública operacional.

## Segunda adoção: Firecrawl

O Firecrawl foi migrado depois que o fluxo do `cloudflared` estava comprovado. A aplicação já estava operacional no K3s; o Flux passou a assumir os recursos existentes sem necessidade de recriar a stack.

A cadeia é independente da Cloudflare:

```text
firecrawl-namespace
        ↓
firecrawl-secrets
        ↓
firecrawl
```

O Secret `firecrawl-secrets` é gerado localmente a partir do `.env`, cifrado com SOPS + age e versionado apenas na forma cifrada. O Flux decripta o Secret no momento da reconciliação.

Em 2026-09-14 foi executado um teste controlado de self-healing: `firecrawl-api` foi escalado manualmente de 1 para 2 réplicas, criando drift positivo sem reduzir a capacidade do serviço. Após `flux reconcile`, o Deployment retornou ao estado declarado de 1 réplica, ficou disponível e `http://firecrawl.guiosoft.info/` continuou respondendo HTTP 200 pela LAN.

O teste é reproduzível por:

```bash
bash scripts/firecrawl-gitops-test.sh
```

## Terceira adoção: observabilidade via HelmRelease

A stack de observabilidade já existia como releases Helm operacionais antes da adoção pelo Flux. Para evitar recriação acidental, cada `HelmRelease` foi declarado com `releaseName`, `targetNamespace` e `storageNamespace` correspondendo exatamente aos releases existentes e inicialmente ficou com `suspend: true`.

A adoção foi feita uma release por vez, em ordem conservadora de blast radius:

```text
Alloy
  ↓
OpenTelemetry Collector
  ↓
Tempo
  ↓
Loki
  ↓
kube-prometheus-stack
```

As versões adotadas foram preservadas:

```text
alloy                    1.12.1
otel-collector           opentelemetry-collector 0.172.1
tempo                    2.2.3
loki                     18.5.0
kube-prometheus-stack    89.2.0
```

Cada release foi ativado individualmente (`suspend: false`) e reconciliado antes de avançar para o próximo componente.

A validação cobriu:

- `HelmRelease` com `Ready=True`;
- release Helm runtime existente e `deployed`;
- Pods/StatefulSets/Deployments preservados e Ready;
- PVCs de Tempo, Prometheus e Grafana preservados;
- OTLP `4317/4318` no OpenTelemetry Collector;
- trace distribuído `otel-go-demo -> OTel Collector -> Tempo`;
- logs `otel-go-demo -> Alloy -> Loki` com lookup por `trace_id`;
- Prometheus Operator CRDs;
- targets, métricas e PVCs via `make observability-validate`.

O script `scripts/observability-gitops-stage.sh`, originalmente criado para validar o estágio suspenso, agora valida o estado final de ownership: os cinco HelmReleases devem estar ativos, `Ready`, com releases Helm runtime `deployed` e HelmRepositories `Ready`.

## SOPS + age

O Flux usa decriptação SOPS diretamente nas Kustomizations de secrets:

```yaml
decryption:
  provider: sops
  secretRef:
    name: sops-age
```

A identidade privada age necessária para decriptação é instalada no namespace `flux-system` como Secret runtime e **não é versionada em plaintext**.

Os arquivos SOPS mantêm `apiVersion`, `kind` e `metadata` legíveis e criptografam somente `data`/`stringData` com:

```text
^(data|stringData)$
```

O recipient público age permanece no repositório; a identidade privada continua fora do Git e precisa de backup independente para DR.

Após o bootstrap do Flux, o Secret runtime pode ser criado ou atualizado de forma idempotente pelo playbook:

```bash
ansible-playbook -i ansible/inventory/production.yml \
  ansible/playbooks/flux-sops-age.yml
```

O playbook usa a identidade já criada pela role `secrets`, exige que o namespace `flux-system` exista, usa o kubeconfig administrativo do K3s e aplica `flux-system/sops-age` sem imprimir a chave privada. As tarefas que manipulam a identidade ou o Secret usam `no_log: true`.

A validação recomendada é executar o playbook duas vezes: a primeira execução pode criar/atualizar o Secret; a segunda deve ser idempotente. Essa validação runtime ainda deve ser registrada antes de considerar o bootstrap totalmente comprovado para DR.

## Testes de recuperação, drift e rollback

As provas realizadas até agora cobrem:

```text
Git cifrado -> Flux -> SOPS/age -> Kubernetes Secret -> workload
Git -> cluster
manual drift -> self-healing para o estado do Git
Git change -> cluster
Git rollback -> cluster
Helm existente -> HelmRelease Flux -> reconciliação sem recriação
```

No `cloudflared`, o Secret foi excluído manualmente e recriado pelo Flux a partir do Git cifrado. Também foram validados drift de réplicas e mudança/rollback de annotation via Git sem indisponibilidade pública.

No Firecrawl, o drift controlado de réplicas foi restaurado pelo Flux e o endpoint LAN permaneceu HTTP 200.

Na observabilidade, os releases existentes foram adotados individualmente, preservando workloads, storage e integração funcional entre métricas, traces e logs.

## Prune e segurança

`prune` está habilitado apenas em escopos pequenos e conhecidos. Recursos críticos não são transferidos para Flux sem antes confirmar:

- ownership declarativo claro;
- backup/rollback apropriado;
- ausência de recursos gerados manualmente dentro do mesmo escopo;
- resultado de build/diff quando aplicável.

Terraform continua responsável por Cloudflare/R2 e Ansible continua responsável pelo host/K3s. Flux não substitui essas camadas.

## Estado atual da adoção

Concluído:

- Flux CLI via Ansible;
- bootstrap GitHub;
- controllers Flux operacionais;
- `flux-system` reconciliando a própria configuração;
- `cloudflared` sob Flux com namespace e Secret SOPS independentes;
- Firecrawl sob Flux com namespace e Secret SOPS independentes;
- dependências explícitas `namespace -> secrets -> workload`;
- recuperação real de Secret a partir de Git + SOPS + age;
- correção automática de drift manual;
- mudança e rollback declarativo via Git;
- teste de self-healing do Firecrawl preservando disponibilidade LAN;
- Alloy sob HelmRelease Flux;
- OpenTelemetry Collector sob HelmRelease Flux;
- Tempo sob HelmRelease Flux;
- Loki sob HelmRelease Flux;
- kube-prometheus-stack sob HelmRelease Flux;
- toda a stack atual de observabilidade reconciliada por Flux;
- playbook pós-bootstrap para criar/atualizar `flux-system/sops-age` sem expor a chave privada.

Pendências relacionadas ao GitOps/DR:

1. validar o playbook `flux-sops-age.yml` em duas execuções consecutivas e registrar a idempotência;
2. manter backup off-host independente da identidade privada age;
3. expandir o modelo GitOps apenas quando novos workloads forem incorporados.

## Rollback operacional

A primeira resposta a problemas de reconciliação deve ser suspender apenas a Kustomization ou HelmRelease afetado.

Exemplo para Firecrawl:

```bash
flux suspend kustomization firecrawl -n flux-system
```

Exemplo para um release de observabilidade:

```bash
flux suspend helmrelease tempo -n monitoring
```

Mudanças declarativas devem ser revertidas no Git e reconciliadas novamente. A remoção completa do Flux não é o mecanismo normal de rollback.

## Fontes oficiais

- Flux bootstrap for GitHub: https://fluxcd.io/flux/installation/bootstrap/github/
- Flux Kustomization / SOPS decryption: https://fluxcd.io/flux/components/kustomize/kustomizations/
- Flux HelmRelease: https://fluxcd.io/flux/components/helm/helmreleases/
- Flux HelmRepository: https://fluxcd.io/flux/components/source/helmrepositories/
- Flux releases: https://github.com/fluxcd/flux2/releases
