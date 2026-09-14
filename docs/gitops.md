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

## Testes de recuperação, drift e rollback

As provas realizadas até agora cobrem:

```text
Git cifrado -> Flux -> SOPS/age -> Kubernetes Secret -> workload
Git -> cluster
manual drift -> self-healing para o estado do Git
Git change -> cluster
Git rollback -> cluster
```

No `cloudflared`, o Secret foi excluído manualmente e recriado pelo Flux a partir do Git cifrado. Também foram validados drift de réplicas e mudança/rollback de annotation via Git sem indisponibilidade pública.

No Firecrawl, o drift controlado de réplicas foi restaurado pelo Flux e o endpoint LAN permaneceu HTTP 200.

## Prune e segurança

`prune` está habilitado apenas em escopos pequenos e conhecidos. Recursos críticos não serão transferidos para Flux sem antes confirmar:

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
- teste de self-healing do Firecrawl preservando disponibilidade LAN.

Próximo candidato de adoção:

1. observabilidade/Helm, por último entre os componentes atuais.

## Rollback operacional

A primeira resposta a problemas de reconciliação deve ser suspender apenas a Kustomization afetada:

```bash
flux suspend kustomization firecrawl -n flux-system
```

ou, para o Tunnel:

```bash
flux suspend kustomization cloudflared -n flux-system
```

Mudanças declarativas devem ser revertidas no Git e reconciliadas novamente. A remoção completa do Flux não é o mecanismo normal de rollback.

## Fontes oficiais

- Flux bootstrap for GitHub: https://fluxcd.io/flux/installation/bootstrap/github/
- Flux Kustomization / SOPS decryption: https://fluxcd.io/flux/components/kustomize/kustomizations/
- Flux releases: https://github.com/fluxcd/flux2/releases
