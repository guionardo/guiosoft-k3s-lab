# Registry OCI LAN-only no K3s — desenho

Data: 2026-10-30
Status: aguardando aprovação

## Intenção

Hoje, publicar uma imagem no cluster exige o node. O fluxo do `gh-eva`
(`deploy/gh-eva-api-k3s-local.sh`) constrói a imagem na estação de trabalho,
faz `docker save` para um tar, sobe um pod temporário em `kube-system` com
`hostPath` no socket do containerd, copia o tar para dentro do pod e executa
`ctr images import`, para só então aplicar o Deployment.

Três problemas concretos nisso:

1. **O socket do containerd é root-equivalente no node.** Qualquer pod que o
   monte pode importar, apagar ou substituir imagens. É um caminho de execução
   de código arbitrário que existe apenas para transporte.
2. **O fluxo depende de acesso ao node**, então não funciona de outra máquina
   da LAN nem de um hipotético CI.
3. **Não há digest pinado.** Tag timestampada + import local não gera
   referência imutável, ao contrário do que o repositório já faz com Firecrawl
   e `cloudflared`.

Um registry OCI dentro do cluster substitui os passos 2–4 por `docker push`,
elimina o pod privilegiado e devolve tags/digests endereçáveis.

O registry é **cache descartável**: toda imagem nele deve poder ser
reconstruída a partir do git. Ele não é fonte de verdade, não entra no
recovery set e não pode se tornar dependência de DR.

## Escopo

Objetivo: um registry OCI privado, acessível apenas pela LAN, que aceita push
de uma estação da LAN e serve pull para os pods do cluster.

### Não-objetivos

- Build dentro do cluster (Shipwright, Tekton, BuildKit, Kaniko). O build
  continua na estação de trabalho, como hoje.
- Exposição pública. Desenhamos para que a exposição futura seja uma mudança
  de configuração, não de arquitetura.
- CI/CD, webhooks, automação de bump de tag, Flux Image Automation.
- RBAC multi-tenant, quotas por projeto, assinatura de imagem (cosign),
  replicação, HA.
- Migrar `guiosoft/otel-go-demo:dev` ou os workloads que usam
  `imagePullPolicy: Never`. Fica para depois, se valer a pena.

### Anti-objetivos

O desenho falhou se:

- o registry virar load-bearing para recuperação de desastre;
- existir imagem em produção cuja única cópia esteja no registry;
- o registry precisar de WAN para funcionar (o cluster é testado isolado);
- a operação correta exigir acesso root ao node no dia a dia.

## Restrições verificadas no repositório, no cluster e no host

- K3s `v1.36.4+k3s1`, single-node, Debian 13, datastore SQLite.
- Traefik como ingress controller e ServiceLB, atendendo `192.168.88.9:80/443`.
  O TLS público termina no Cloudflare; internamente o tráfego é HTTP.
- **Não há cert-manager** e não há CA interna no cluster.
- Storage: local-path em `/mnt/store1/k3s/local-path`. `/mnt/store1` tem
  916 GB com 570 GB livres (35% usado); a soma declarada dos PVCs existentes
  é 91 Gi, sem pré-alocação.
- `scripts/k3s-pv-backup-r2.sh` executa `restic backup "$PV_ROOT"` sobre a raiz
  inteira do local-path: qualquer PVC novo entra no snapshot por padrão.
  O *rehearsal set* é diferente — é uma allowlist explícita de quatro PVCs em
  `scripts/dr-preflight.sh`.
- Secrets: SOPS + age (`.sops.yaml`), aplicados por `scripts/sops-k8s-secret.sh`.
- Declaração: Flux lê `clusters/guiosoft-info/` e reconcilia
  `kubernetes/apps/<app>` e `kubernetes/namespaces/<ns>`.
  `docs/gitops.md` fixa que Flux não assume responsabilidades de host/K3s.
- **DNS:** `terraform/cloudflare/main.tf` mantém um wildcard
  `*.guiosoft.info -> http://192.168.88.9:80` e hosts LAN-only são protegidos
  por regra explícita `http_status:404` colocada antes do wildcard (precedente:
  `firecrawl.guiosoft.info`). Verificado agora: `registry.guiosoft.info` **já
  resolve publicamente** para IPs do Cloudflare (104.21.7.18), e apenas
  `firecrawl.guiosoft.info` tem entrada de split-DNS no MikroTik apontando
  para `192.168.88.9`.
- Ansible escreve `/etc/rancher/k3s/config.yaml` em `ansible/roles/k3s/tasks/main.yml`
  e já possui handler `Restart k3s`.
- Política do repositório: imagens pinadas por digest, `local-path` para
  estado, R2/Restic para o que precisa sobreviver.

## Decisões já tomadas

- **LAN-only agora, público no futuro.** Consequência de desenho: o registry é
  endereçado por **hostname sem porta** desde o primeiro push
  (`registry.guiosoft.info/...`). A exposição futura passa a ser adicionar um
  certificado válido, sem renomear imagens.
- **Cache descartável.** Imagens sempre reconstruíveis do git. Sem backup do
  PVC, sem entrada no recovery set, sem expectativa de durabilidade.

## Decisões de implementação (minhas, revisáveis)

1. **Zot** (`ghcr.io/project-zot/zot`, pinado por digest) em vez de
   `distribution/distribution`. Motivo: o registry é cache descartável, então
   poda automática não é opcional. Zot tem GC e políticas de retenção
   declarativas em config; `registry:2` exige cronjob externo, parada do
   registry e `garbage-collect` por `exec`.
2. **443, não 80.** O cliente Docker assume 443 para referência sem porta; com
   HTTP na 80 a referência teria que carregar `:80`, reintroduzindo exatamente
   o rename que a decisão de hostname quis evitar. Então: Ingress do Traefik em
   `registry.guiosoft.info` com `tls`, usando o certificado autoassinado padrão
   do Traefik, e clientes marcados como `insecure` (Docker
   `insecure-registries`, containerd `insecure: true`). O certificado não é
   confiável — e não precisa ser, porque a verificação está desligada dos dois
   lados. Subir para TLS real depois é trocar o certificado e remover a flag
   `insecure` dos clientes.
3. **Regra de bloqueio no Cloudflare é entregável, não detalhe.** O hostname já
   é público por wildcard; sem uma entrada `registry.guiosoft.info ->
   http_status:404` antes do wildcard em `terraform/cloudflare/main.tf`, o
   registry fica exposto na internet no instante em que o Ingress reconciliar.
   Entra junto com a entrada de split-DNS no MikroTik (pré-requisito manual,
   mesmo formato do Firecrawl).
4. **`/etc/hosts` gerenciado pelo Ansible** no node, apontando
   `registry.guiosoft.info -> 192.168.88.9`, para o containerd não depender de
   o node usar o MikroTik como resolver. O split-DNS continua sendo o caminho
   das estações.
5. **Autenticação desde o início** com `htpasswd` (Secret via SOPS), dois
   usuários: um de push (uso humano, `docker login`) e um de pull (pods).
   Push aberto na LAN equivale a permitir que qualquer host do segmento escolha
   o que roda nos workloads. A restrição read-only por usuário depende do
   suporte do Zot a `accessControl` com htpasswd; validar na implementação e,
   se não existir, registrar que a separação é operacional, não imposta.
6. **Contrato de credencial entre repositórios.** Este repositório possui o
   registry e o `htpasswd`. Cada repositório consumidor cria seu próprio
   `docker-registry` pull secret no próprio namespace — no caso do `gh-eva`,
   pelo seu script, com o mesmo padrão já usado para `GH_EVA_API_SEND_KEY`
   (lê do ambiente ou de Secret existente, gera se ausente). Assim nenhum
   repositório escreve Secret em namespace que não gerencia.
7. **PVC de 20 Gi em `local-path`**, sem backup. Se precisar crescer, recriar é
   aceitável — é cache.
8. **Exclusão do backup resolvida dinamicamente.** `k3s-pv-backup-r2.sh` passa a
   calcular o diretório do PV do registry a partir do `claimRef` e a passá-lo em
   `restic backup --exclude`. Um caminho literal `pvc-<uuid>` quebraria em
   silêncio no dia que o PVC fosse recriado. O *rehearsal set* não muda: já é
   allowlist explícita.
9. **Timeouts do Traefik via `HelmChartConfig`** em
   `/var/lib/rancher/k3s/server/manifests/`, território do Ansible, coerente com
   a fronteira de `docs/gitops.md`. Causa um rollout do Traefik; agendar junto
   com o restart do k3s para não somar dois blips.
10. **Alerta de espaço livre em `/mnt/store1`**, que `docs/storage.md` deixa em
    aberto. `PrometheusRule` com
    `node_filesystem_avail_bytes{mountpoint="/mnt/store1"}`, no mesmo formato de
    `kubernetes/apps/otel-go-demo/prometheus-rules.yaml`.
11. **Tags imutáveis na prática**: `k3s-<timestamp>` como hoje. Digest pinado
    fica como evolução, não como pré-requisito.

## Partes do como

### Componentes

```text
estação (docker build, insecure-registries)   pods (containerd, insecure mirror)
                  |                                        |
                  | docker push                            | pull
                  v                                        v
        registry.guiosoft.info:443  -->  Traefik  -->  zot:5000  -->  PVC local-path
```

- Namespace `registry`.
- `kubernetes/namespaces/registry/` com namespace e kustomization, seguindo
  `kubernetes/namespaces/planetapeia/`.
- `kubernetes/apps/registry/` com `configmap.yaml` (config do Zot),
  `pvc.yaml`, `deployment.yaml`, `service.yaml`, `ingress.yaml`,
  `registry-alerts.yaml` e `kustomization.yaml`.
- Entrada em `clusters/guiosoft-info/` no formato de `planetapeia.yaml`, com
  `dependsOn` do Kustomization do secret, `wait: true` e health check de PVC.

### Configuração do Zot (forma, não conteúdo final)

- `storage.rootDirectory: /var/lib/registry`
- `http.port: 5000`, `http.auth.htpasswd.path` no arquivo montado do Secret.
- `storage.gc: true` e `storage.retention` conservadora: manter as últimas N
  tags por repositório e descartar além de uma janela de dias. Números exatos
  são decisão do implementador, calibrados para 20 Gi.

### Mudanças no K3s (Ansible)

- `ansible/roles/k3s/tasks/main.yml`: escrever
  `/etc/rancher/k3s/registries.yaml` com o mirror do hostname marcado
  `insecure: true`, com `notify: Restart k3s`.
- Linha em `/etc/hosts` para o hostname.
- `HelmChartConfig` do Traefik com `respondingTimeouts` elevado.

### Mudanças fora deste repositório

- **Cloudflare/Terraform:** entrada `registry.guiosoft.info -> http_status:404`
  em `terraform/cloudflare/main.tf`, antes do wildcard, aplicada com
  `make tf-cloudflare-plan` e revisão do plano.
- **MikroTik:** entrada de split-DNS `registry.guiosoft.info -> 192.168.88.9`,
  manual, documentada como pré-requisito de aceitação.
- **`gh-eva`:** em `deploy/gh-eva-api-k3s-local.sh`, remover `docker save`,
  `mktemp`, o pod `gh-eva-api-image-import`, o `hostPath` do socket,
  `kubectl cp`, `kubectl exec`, `ctr images import` e o trap do pod; manter
  `docker build --platform linux/amd64` com tag timestampada prefixada por
  `registry.guiosoft.info/gh-eva/`; adicionar `docker push`, `docker login`
  quando necessário e `imagePullSecrets` no Deployment.

### Operação no repositório

Alvos de Makefile no padrão existente (`registry-install`, `registry-status`,
`registry-validate`), script em `scripts/`, e `docs/registry.md` no formato dos
documentos existentes. Atualização de `docs/roadmap.md`,
`docs/current-state.md` e `docs/disaster-recovery.md` (registrando a exclusão
deliberada).

### Verificação

1. `kubectl -n registry get pods` com Pod `Ready` e PVC `Bound`.
2. `registry.guiosoft.info` bloqueado publicamente: requisição externa retorna
   404 do Tunnel, enquanto a LAN resolve para `192.168.88.9`.
3. Push de uma imagem de teste a partir da estação da LAN, sem acesso ao node.
4. Pull por um pod com `imagePullSecret`, provando que o containerd resolve e
   confia no endpoint.
5. Push sem credenciais rejeitado.
6. `restic backup --dry-run` provando que o diretório do PVC do registry fica
   fora do snapshot.
7. Retenção: publicar mais tags que o limite, confirmar coleta e liberação de
   espaço.
8. Rollback: remover a entrada do Flux, confirmar que pods em execução
   continuam rodando do cache do containerd.

## Riscos conhecidos

| Risco | Mitigação |
|---|---|
| Restart do k3s para `registries.yaml` causa blip de control-plane em single-node | Um restart só, agendado, Traefik rollout junto |
| Registry fica público por esquecimento da regra do Tunnel | Regra no Terraform é entregável e item de verificação |
| Registry enche o disco e derruba o node | Retenção + GC, PVC 20 Gi contra 570 GB livres, alerta de espaço |
| Traefik derruba push grande por timeout | `HelmChartConfig` com `respondingTimeouts`, teste com layer grande |
| Registry vira dependência silenciosa de DR | Exclusão no backup + política de reconstrução + registro em `docs/disaster-recovery.md` |
| Credencial de pull com poder de push | Dois usuários; se o Zot não impor read-only, registrar como dívida |
| Host da LAN sem split-DNS empurra para o Cloudflare e recebe 404 | Pré-requisito documentado; `/etc/hosts` como fallback por estação |

## O que fica para o implementador

- Números de retenção e tamanho final do PVC.
- Estrutura exata dos manifests e nomes de objeto.
- Flags dos alvos de Makefile e do script de validação.
- Redação de `docs/registry.md` e das atualizações de roadmap/estado atual.
- Digest exato da imagem do Zot, resolvido na instalação.
- Validar se o Zot impõe read-only por usuário em htpasswd.

## Registro da revisão independente

O documento foi revisado por um engenheiro de plataforma sem acesso ao autor.
As objeções levantadas e o destino de cada uma:

| Objeção | Destino |
|---|---|
| Hostname sem porta é incompatível com HTTP na 80 | Aceita — mudou para 443 com certificado autoassinado e clientes `insecure` |
| Regra de bloqueio no Tunnel não estava no escopo | Aceita — virou entregável e item de verificação |
| Dono da credencial entre repositórios indefinido | Aceita — contrato explícito, cada repo cria seu pull secret |
| `--exclude` literal quebra quando o PVC é recriado | Aceita — exclusão resolvida dinamicamente pelo `claimRef` |
| Alerta de espaço prometido mas não entregue | Aceita — `PrometheusRule` incluído |
| `registry.guiosoft.info` não resolve na LAN | Confirmado por DNS e incorporado como pré-requisito |
| Onde vivem os timeouts do Traefik | Aceita — `HelmChartConfig` gerenciado pelo Ansible |
