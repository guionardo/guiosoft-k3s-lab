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
    │   ├── gotk-components.yaml
    │   ├── gotk-sync.yaml
    │   └── kustomization.yaml
    ├── cloudflare-namespace.yaml
    ├── cloudflare-secrets.yaml
    ├── cloudflared.yaml
    └── kustomization.yaml
```

Os manifests de aplicações continuam organizados sob `kubernetes/`. A adoção é incremental para manter rollback simples.

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

A adoção foi feita sem recriar o workload: os recursos Kubernetes já existentes foram assumidos pela reconciliação do Flux e permaneceram operacionais durante a transição.

A ordem atual de reconciliação é:

```text
cloudflare-namespace
        ↓
cloudflare-secrets
        ↓
cloudflared
```

Isso garante que o namespace exista antes de aplicar Secrets e que o Deployment só reconcilie depois que os secrets necessários estiverem disponíveis.

## SOPS + age

O Flux usa decriptação SOPS diretamente em `Kustomization`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cloudflare-secrets
  namespace: flux-system
spec:
  interval: 10m
  path: ./kubernetes/secrets
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

A identidade privada age necessária para decriptação é instalada no namespace `flux-system` como Secret runtime e **não é versionada em plaintext**.

O arquivo SOPS deve manter `apiVersion`, `kind` e `metadata` legíveis, criptografando apenas `data`/`stringData`. O Secret do Tunnel segue esse padrão.

## Teste de recuperação do Secret

Em 2026-09-14 foi validado o fluxo completo de recuperação:

1. o Secret `cloudflared-tunnel-token` foi removido manualmente do namespace `cloudflare`;
2. `cloudflare-secrets` foi reconciliado pelo Flux;
3. o Secret foi recriado a partir do manifesto cifrado no Git;
4. o `cloudflared` permaneceu saudável;
5. `https://k3s-test.guiosoft.info/` continuou respondendo HTTP 200.

Isso valida a cadeia:

```text
Git cifrado -> Flux -> SOPS/age -> Kubernetes Secret -> workload operacional
```

O recipient público age permanece no repositório; a identidade privada continua fora do Git e precisa de backup independente para DR.

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
- namespace `cloudflare` sob Flux;
- Secret SOPS do Tunnel sob Flux;
- workload `cloudflared` sob Flux;
- dependências explícitas entre namespace, secrets e workload;
- recuperação real do Secret a partir de Git + SOPS + age sem indisponibilidade pública.

Próximos candidatos de adoção:

1. executar teste simples de drift/rollback declarativo no `cloudflared`;
2. migrar Firecrawl para Flux;
3. migrar observabilidade/Helm por último.

## Rollback operacional

A primeira resposta a problemas de reconciliação deve ser suspender a Kustomization afetada, não remover o Flux:

```bash
flux suspend kustomization cloudflared -n flux-system
```

Mudanças declarativas devem ser revertidas no Git e reconciliadas novamente. A remoção completa do Flux não é o mecanismo normal de rollback.

## Fontes oficiais

- Flux bootstrap for GitHub: https://fluxcd.io/flux/installation/bootstrap/github/
- Flux Kustomization / SOPS decryption: https://fluxcd.io/flux/components/kustomize/kustomizations/
- Flux releases: https://github.com/fluxcd/flux2/releases
