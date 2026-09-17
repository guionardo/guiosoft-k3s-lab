# GitOps, secrets e infraestrutura reproduzível

Depois de colocar aplicações e observabilidade no meu cluster K3s, uma pergunta começou a incomodar:

**quanto desse ambiente existe porque está declarado — e quanto existe apenas porque eu me lembro dos comandos que executei?**

Essa diferença é pequena enquanto o servidor está funcionando. Em uma reconstrução, ela é enorme.

Foi por isso que a etapa seguinte do meu homelab não foi instalar mais uma aplicação. Foi reduzir o número de decisões que existiam apenas no estado atual da máquina.

## Três camadas, três responsabilidades

O projeto acabou adotando uma separação simples:

```text
Ansible
  -> estado do Debian e K3s

Terraform
  -> recursos externos

Flux / Kubernetes / Helm
  -> estado interno do cluster
```

Não quis usar Terraform para instalar K3s no servidor físico, nem Flux para configurar o Debian.

As ferramentas se sobrepõem em capacidade, mas isso não significa que devam se sobrepor em ownership.

Para mim, uma infraestrutura reproduzível começa quando fica claro **quem é responsável por cada estado**.

## Por que Flux?

Escolhi Flux para GitOps porque o repositório já possuía manifests Kubernetes e Helm, e eu já havia adotado SOPS + age para secrets.

O suporte nativo à decriptação SOPS no `kustomize-controller` tornou a combinação particularmente simples.

Outro ponto foi o modelo pull-based: depois do bootstrap, o cluster consulta o repositório e reconcilia seu próprio estado. Eu não precisava introduzir um servidor de CD separado apenas para esse laboratório.

Isso não torna outras ferramentas inválidas. Argo CD, por exemplo, continua sendo uma excelente alternativa quando UI e fluxos visuais de Applications são uma prioridade. No meu caso, Flux encaixou melhor no estado que o projeto já tinha.

## Começar pelo workload menos perigoso

O primeiro workload que coloquei sob ownership do Flux foi o `cloudflared`.

A escolha foi proposital: pequeno, stateless, declarativo e com rollback simples.

A dependência ficou explícita:

```text
namespace
   |
secret SOPS
   |
cloudflared
```

Depois de validar essa cadeia, fiz testes de drift manual, mudança versionada e rollback pelo Git.

Também removi deliberadamente um Secret do cluster e confirmei sua reconstrução a partir do arquivo cifrado no repositório.

Esse teste foi importante porque GitOps sem teste de reconstrução pode ser apenas sincronização otimista.

## Secrets no Git — mas não em plaintext

Minha regra é simples: nenhum secret em texto puro deve ser versionado.

Os manifests sensíveis são cifrados com SOPS + age. O recipient público pode permanecer no repositório. A identidade privada não.

O fluxo é aproximadamente:

```text
Git
 |
 | Secret cifrado com SOPS
 v
Flux
 |
 | usa identidade age runtime
 v
Secret Kubernetes
 |
 v
workload
```

Nos manifests SOPS, metadata permanece legível e apenas `data`/`stringData` são cifrados. Isso mantém o arquivo identificável sem revelar o conteúdo sensível.

A identidade privada age é instalada no namespace `flux-system` como Secret runtime, mas sua origem permanece fora do Git.

Essa decisão produz uma consequência importante para Disaster Recovery: **Git sozinho não reconstrói o cluster**.

É preciso possuir também uma cópia independente da identidade privada que permite abrir os secrets.

Mais tarde eu criaria exatamente esse backup off-host e testaria sua recuperação.

## Self-healing precisa ser observado

Depois do `cloudflared`, migrei o Firecrawl para ownership do Flux.

Para testar reconciliação sem provocar indisponibilidade, escalei manualmente a API de uma para duas réplicas. Era um drift positivo: capacidade extra, não capacidade removida.

Depois de uma reconciliação, o Deployment voltou para uma réplica, exatamente como declarado no Git, e o endpoint continuou respondendo.

A ideia do teste não era provar que `kubectl scale` funciona. Era confirmar esta cadeia:

```text
estado declarado no Git
        !=
estado manual no cluster
        |
        v
Flux detecta/reconcilia
        |
        v
estado volta ao Git
```

## Adotar recursos existentes sem recriá-los

A observabilidade apresentou um desafio mais interessante.

Prometheus, Grafana, Loki, Tempo, Alloy e OpenTelemetry Collector já estavam funcionando antes do Flux assumir ownership.

Eu não queria transformar a adoção de GitOps em uma reinstalação da stack.

Os HelmReleases foram declarados com `releaseName`, `targetNamespace` e `storageNamespace` correspondendo aos releases existentes e começaram suspensos.

Depois foram ativados um a um, em uma ordem conservadora:

```text
Alloy
  -> OpenTelemetry Collector
  -> Tempo
  -> Loki
  -> kube-prometheus-stack
```

A cada etapa eu validava HelmRelease Ready, release runtime deployed, Pods, PVCs e os fluxos funcionais de métricas, logs e traces.

Isso transformou a adoção de GitOps em uma migração de ownership, não em um redeploy cego.

## GitOps não substitui rollback

Uma coisa que quis preservar desde o início foi a capacidade de interromper a automação.

Se uma reconciliação estiver causando problema, a primeira resposta não precisa ser remover o Flux inteiro. É possível suspender somente a Kustomization ou HelmRelease afetado, corrigir o estado no Git e então reconciliar novamente.

O mesmo princípio aparece em várias partes deste projeto: automação é útil quando também possui um caminho claro de interrupção e rollback.

## Idempotência como evidência

O Ansible também participa da reconstrução do runtime SOPS.

O playbook que instala/atualiza a identidade age no `flux-system` foi executado novamente depois de o Secret já existir e terminou com:

```text
ok=8
changed=0
failed=0
```

Mais recentemente, reorganizei as variáveis do Ansible para separar explicitamente configuração comum, produção e DR. Depois da mudança, o dry-run em produção terminou com:

```text
ok=16
changed=0
failed=0
```

No inventário de DR, por outro lado, backup consistente, R2 e `cloudflared` são `false` por padrão.

Não é apenas organização de YAML. É redução de blast radius: um host de recuperação não deve herdar silenciosamente políticas operacionais da produção.

## O que o Git consegue reconstruir?

Depois dessa etapa, o repositório passou a representar uma parte muito maior do sistema:

```text
Git -> Flux -> Kubernetes
Git cifrado -> SOPS/age -> Secrets
Ansible -> host/K3s
Terraform -> recursos externos
```

Mas a pergunta de reconstrução ainda não estava respondida.

Eu tinha configuração declarativa. Tinha secrets cifrados. Tinha backups.

Então surgiu a pergunta que acabou mudando o rumo do projeto:

**se o servidor desaparecer, eu realmente consigo restaurar tudo em outra máquina?**

Ter backup e conseguir fazer Disaster Recovery são coisas diferentes.

Eu descobri isso executando o restore de verdade.

Esse será o próximo artigo.

---

Projeto: `guionardo/guiosoft-k3s-lab`.
