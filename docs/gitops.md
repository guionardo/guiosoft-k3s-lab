# GitOps com Flux

## Decisão

A Fase 7 adotará **Flux** como controlador GitOps do cluster.

A escolha foi feita principalmente por aderência ao estado atual do projeto:

- o repositório já contém manifests Kubernetes e configurações Helm versionadas;
- SOPS + age já é o padrão de secrets do laboratório;
- o `kustomize-controller` do Flux possui decriptação SOPS nativa;
- o bootstrap oficial pode gravar os manifests do próprio Flux no repositório e depois reconciliá-los a partir do Git;
- não precisamos introduzir uma UI/CD server adicional somente para operar o laboratório;
- o modelo pull-based combina com o objetivo de reconstrução declarativa do cluster.

Argo CD continua sendo uma alternativa válida, especialmente quando UI, catálogo de Applications e fluxos operacionais visuais forem prioridade. Para este cluster, porém, o suporte SOPS nativo do Flux reduz componentes e customizações.

## Versão inicial

Versão de referência escolhida em 2026-09-14:

```text
Flux v2.9.5
```

A versão deve continuar pinada/registrada na automação de instalação, em vez de depender silenciosamente de `latest`.

## Layout GitOps planejado

O bootstrap usará:

```text
clusters/
└── guiosoft-info/
    └── flux-system/
        ├── gotk-components.yaml
        ├── gotk-sync.yaml
        └── kustomization.yaml
```

Os manifests de aplicações continuam organizados sob `kubernetes/`. A primeira etapa não reorganizará todos os manifests de uma vez: a adoção será incremental para manter rollback simples.

## Bootstrap GitHub

O repositório é:

```text
guionardo/guiosoft-k3s-lab
```

O bootstrap recomendado usa chave SSH/deploy key para o acesso runtime do Flux ao GitHub:

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

Um GitHub token/PAT é necessário para a operação de bootstrap no GitHub, mas com `--token-auth=false` o acesso runtime do Flux ao repositório usa SSH/deploy key em vez de manter o PAT como credencial Git do cluster.

Não versionar o PAT.

## Estratégia de adoção

A ordem será deliberadamente incremental:

1. bootstrap do Flux e validação dos controllers;
2. confirmar que `flux-system` reconcilia o próprio bootstrap a partir do Git;
3. criar uma `Kustomization` pequena para um workload de laboratório;
4. validar drift/self-healing controlado;
5. integrar SOPS + age ao `kustomize-controller`;
6. migrar `cloudflared`, que já possui manifests simples e Secret SOPS;
7. migrar Firecrawl;
8. migrar observabilidade/Helm por último, preservando os procedimentos atuais durante a transição.

Não colocaremos todos os recursos sob reconciliação automática em uma única mudança.

## SOPS + age

O Flux suporta decriptação SOPS diretamente em `Kustomization`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: example
  namespace: flux-system
spec:
  interval: 10m
  path: ./kubernetes/apps/example
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

A identidade privada age necessária para decriptação será instalada no namespace `flux-system` como Secret runtime e **não será versionada em plaintext**.

Antes de mover secrets existentes para reconciliação Flux, verificar se o formato SOPS atual é compatível com o `kustomize-controller`. Em particular, `apiVersion`, `kind` e `metadata` devem permanecer legíveis e a criptografia deve se concentrar em `data`/`stringData`.

## Prune e segurança

No começo, `prune` será habilitado apenas em escopos pequenos e conhecidos. Recursos críticos não serão transferidos para Flux sem antes confirmar:

- ownership declarativo claro;
- backup/rollback apropriado;
- ausência de recursos gerados manualmente dentro do mesmo escopo;
- resultado de `flux diff`/build quando aplicável.

Terraform continua responsável por Cloudflare/R2 e Ansible continua responsável pelo host/K3s. Flux não substitui essas camadas.

## Critério de sucesso do bootstrap

O bootstrap estará concluído quando:

```bash
flux check
kubectl get pods -n flux-system
flux get sources git -A
flux get kustomizations -A
```

mostrarem todos os controllers saudáveis, source Git Ready e a Kustomization `flux-system` reconciliada.

## Rollback inicial

Enquanto apenas o bootstrap estiver sob GitOps, rollback continua simples: suspender a reconciliação antes de qualquer intervenção manual relevante.

```bash
flux suspend kustomization flux-system -n flux-system
```

A remoção completa do Flux não será usada como primeira resposta a incidentes. Primeiro suspenderemos a reconciliação e analisaremos o drift/erro.

## Fontes oficiais

- Flux bootstrap for GitHub: https://fluxcd.io/flux/installation/bootstrap/github/
- Flux Kustomization / SOPS decryption: https://fluxcd.io/flux/components/kustomize/kustomizations/
- Flux releases: https://github.com/fluxcd/flux2/releases
