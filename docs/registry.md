# Registry OCI LAN-only

## O que é e por que existe

O registry é um [Zot](https://github.com/project-zot/zot) v2.1.22 pinado por digest, executando no namespace `registry` como Deployment `zot`, com dados em um PVC `local-path` de 20Gi (`registry/registry-data`).

Ele existe para publicar e consumir imagens OCI dentro da LAN com `docker push`/pull padrão, substituindo o fluxo anterior de implantação de imagens construídas localmente:

```text
docker save -> mktemp -> pod privilegiado com hostPath do socket do containerd
            -> kubectl cp -> kubectl exec ctr images import -> trap de limpeza
```

Esse fluxo exigia um Pod privilegiado com `hostPath` no socket do containerd do nó. Com o registry, a imagem é enviada por `docker push` autenticado e os Pods a consomem por `imagePullSecrets`, sem privilégio e sem tocar no socket.

Os manifests ficam em `kubernetes/apps/registry/` e são reconciliados pelo Flux na cadeia:

```text
registry-namespace -> registry-secrets -> registry
```

## Endereço e exposição

O endereço é:

```text
https://registry.guiosoft.info
```

sem porta em nenhuma referência de imagem. O Ingress `registry` usa `ingressClassName: traefik`, TLS com o certificado autoassinado padrão do Traefik (sem `secretName`) e está pinado ao entrypoint `websecure` pela anotação:

```yaml
traefik.ingress.kubernetes.io/router.entrypoints: websecure
```

O registry é **LAN-only**. A rota pública possui duas camadas de bloqueio:

1. regra explícita `registry.guiosoft.info -> http_status:404` antes do wildcard no Cloudflare Tunnel, declarada em `terraform/cloudflare/main.tf` — **pendente de `terraform apply`** (não há credenciais Cloudflare nesta estação);
2. enquanto a regra não é aplicada, o pin ao entrypoint `websecure` faz a rota pública morrer com `404` no próprio Traefik, porque o origin do Tunnel aponta para a porta 80.

O split-DNS no MikroTik (`registry.guiosoft.info -> 192.168.88.9`) é o caminho de acesso da LAN e continua **pendente (passo humano manual)**. Até essa entrada existir, estações da LAN resolvem o hostname para o Cloudflare — veja a seção de diagnóstico.

## Credenciais

Dois usuários htpasswd:

```text
pusher  -> humano/CI; push e pull
puller  -> Pods do cluster; leitura
```

O material é cifrado com SOPS + age e dividido em dois arquivos em `kubernetes/secrets/registry/`:

- `registry-htpasswd.sops.yaml` — o Secret aplicado no cluster (`registry/registry-htpasswd`, chave única `htpasswd`);
- `registry-passwords.sops.yaml` — as senhas em claro, deliberadamente **fora** da kustomization; o Flux nunca a aplica.

As operações SOPS acontecem por SSH no host onde vive a identidade age; a chave privada nunca toca esta estação. Subcomandos:

```bash
bash scripts/registry-credentials.sh generate   # gera senhas novas e cifra os dois arquivos
bash scripts/registry-credentials.sh validate   # valida correspondência senha <-> hash bcrypt
bash scripts/registry-credentials.sh password pusher
bash scripts/registry-credentials.sh password puller
```

O mount do htpasswd é `subPath`; após rodar `generate` e aplicar o novo Secret, o Pod precisa reiniciar para enxergá-lo:

```bash
kubectl -n registry rollout restart deploy/zot
```

**Dívida conhecida:** o zot v2.1.22 autentica via htpasswd, mas não impõe separação leitura/escrita — hoje o `puller` também consegue push. `scripts/registry.sh validate` reporta isso com `warn:` em vez de falhar, e a dívida está registrada em `docs/roadmap.md` (Fase 9).

## Como publicar

`make registry-login` imprime o comando de login:

```bash
docker login registry.guiosoft.info -u pusher
```

A senha é a retornada por `bash scripts/registry-credentials.sh password pusher`.

Enquanto o certificado for o autoassinado padrão do Traefik, o daemon do Docker da estação precisa confiar no host via `insecure-registries` em `/etc/docker/daemon.json` (reinicie o Docker depois):

```json
{
  "insecure-registries": ["registry.guiosoft.info"]
}
```

Enquanto o split-DNS do MikroTik não existir, a estação também precisa da entrada temporária `192.168.88.9 registry.guiosoft.info` no próprio `/etc/hosts`.

Build, tag e push (o padrão de tag usado pela adoção do `gh-eva`):

```bash
TAG="registry.guiosoft.info/gh-eva/gh-eva-api:k3s-$(date +%Y%m%d%H%M%S)"
docker tag gh-eva-api:dev "$TAG"
docker push "$TAG"
```

## Como consumir

Pods consomem com um Secret `docker-registry` e `imagePullSecrets`. Criação do Secret a partir da senha do `puller`:

```bash
kubectl -n <namespace> create secret docker-registry registry-pull \
  --docker-server=registry.guiosoft.info \
  --docker-username=puller \
  --docker-password="$(bash scripts/registry-credentials.sh password puller)"
```

E no workload:

```yaml
spec:
  imagePullSecrets:
    - name: registry-pull
  containers:
    - name: app
      image: registry.guiosoft.info/<repo>/<app>:<tag>
      imagePullPolicy: Always
```

O containerd do nó confia no registry por meio de `/etc/rancher/k3s/registries.yaml` (mirror + `insecure_skip_verify` no bloco top-level `configs`) e de uma entrada em `/etc/hosts`, ambos codificados no role Ansible `k3s`. **Pendente:** o playbook ainda não foi executado no host (`make k3s`); até lá, pulls a partir de Pods falham e a asserção de pull do `validate` imprime `SKIP: containerd trust not active: run the k3s playbook`.

## Retenção e coleta de lixo

A configuração vive no ConfigMap `registry/registry-config` (`config.json` do Zot):

```text
gc: true, gcInterval: 24h
retention: delay 1h, repositórios "**"
keepTags: padrões ".*", mostRecentlyPushedCount: 10
```

Ou seja: por repositório, apenas as **10 tags pushed mais recentemente** são mantidas; as demais ficam elegíveis para coleta, e o GC roda a cada 24h (e no startup do Pod). Imagens publicadas por pipelines de deploy se repõem sozinhas a cada push.

O PVC de 20Gi é capacidade declarada, não reserva física (ver `docs/storage.md`). O risco real é o filesystem `/mnt/store1` encher; para isso existe a PrometheusRule `registry/registry-storage` com o alerta `K3sLocalPathLowFreeSpace` (< 15% de espaço livre por 15m).

## O que acontece se o cache for perdido

O PVC é um **cache descartável**. Se ele for recriado, corrompido ou perdido com o disco:

- o registry volta vazio após o Flux reconciliar `registry` (novo PVC, novo diretório `pvc-<uuid>` em `/mnt/store1/k3s/local-path`);
- Pods já em execução não são afetados — a imagem deles está no cache do containerd do nó;
- imagens que existiam apenas no registry precisam ser reconstruídas da fonte (git) e reenviadas com `docker push` pelos pipelines de deploy;
- nenhum estado do cluster depende do conteúdo do PVC.

## Por que não está no backup

O conteúdo do registry é derivável: imagens são reconstruídas a partir do git e reenviadas. Fazer snapshot disso inflaria o backup de PVs sem agregar capacidade de recuperação. Por isso:

- `scripts/k3s-pv-backup-r2.sh` resolve o diretório do PV a partir do `claimRef` vivo do PVC `registry/registry-data` e o passa como `--exclude` ao `restic backup`; qualquer falha de resolução que não seja "PVC inexistente" aborta o backup em voz alta;
- como a exclusão é calculada em runtime, ela sobrevive a reprovisionamento do PVC (novo `pvc-<uuid>`);
- `scripts/dr-preflight.sh` asserta que nenhum PV do namespace `registry` faz parte do recovery set de DR e falha se aparecer.

O texto normativo está em `docs/disaster-recovery.md` (seção "Registry cache exclusion").

## Como expor publicamente no futuro

Hoje o registry é deliberadamente LAN-only. Para expô-lo publicamente, nesta ordem:

1. **certificado válido** para `registry.guiosoft.info` (ex.: cert-manager/Let's Encrypt) referenciado no Ingress via `tls.secretName`, reavaliando o pin ao entrypoint `websecure`;
2. **remover `insecure-registries`** dos daemons Docker das estações e o `insecure_skip_verify` do `registries.yaml` do role Ansible `k3s` (com nova execução do playbook);
3. **remover a regra `registry.guiosoft.info -> http_status:404`** do bloco `ingress` em `terraform/cloudflare/main.tf` e aplicar;
4. **resolver a dívida do `puller`** — com o hostname público, "credencial de leitura consegue push" deixa de ser risco LAN e vira risco de internet;
5. **re-verificar com `make registry-validate`**, ajustando antes as asserções de bloqueio público do script (hoje elas exigem `404` na rota pública, que passará a responder).

## Diagnóstico

Estado e validação ponta a ponta:

```bash
make registry-status      # Deployment, PVC, Ingress (com o entrypoint) e Pods
make registry-validate    # 7 asserções: resolução, bloqueio público, 401, round trip, puller, push-as-puller, pull por Pod
```

Com os passos humanos pendentes (split-DNS e playbook do k3s), o comportamento **esperado** é:

```bash
bash scripts/registry.sh validate
# error: registry.guiosoft.info resolves publicly; add the MikroTik split-DNS entry
# exit 1 — esperado até a entrada split-DNS existir no MikroTik
```

Para exercitar as asserções LAN antes do split-DNS, fixe o alvo do `--resolve`:

```bash
REGISTRY_RESOLVE_IP=192.168.88.9 bash scripts/registry.sh validate
```

Saída esperada hoje, terminando em `Registry end-to-end validation: OK`:

```text
warn: REGISTRY_RESOLVE_IP is set; continuing with --resolve target 192.168.88.9
public block: https://registry.guiosoft.info/v2/ -> 404 (via Cloudflare <ip>)
unauthenticated LAN: https://registry.guiosoft.info/v2/ -> 401
push/pull round trip: registry/smoke:smoke-<timestamp> (...) -> 201/200/200
pull as puller: registry/smoke:smoke-<timestamp> -> 200
warn: puller can push; read-only separation is not enforced by zot
SKIP: containerd trust not active: run the k3s playbook
```

Sintomas comuns:

- **`401` em `/v2/` sem credencial** — comportamento esperado; é a autenticação htpasswd. `401` no `docker login` significa credencial errada; se as senhas foram regeradas com `generate`, aplique o Secret e reinicie o zot (`rollout restart`).
- **`404 page not found` no push/pull** — quase sempre o hostname resolveu para a rota pública: Cloudflare -> Tunnel -> Traefik:80, e o Ingress só responde no `websecure`. Confirme a resolução na estação (`getent hosts registry.guiosoft.info` deve retornar `192.168.88.9`); até o split-DNS existir, use a entrada temporária em `/etc/hosts`. Um hostname errado sem Ingress também recebe `404` do Traefik (default deny por ausência de rota).
- **erro x509/certificado** — o cliente não confia no certificado autoassinado; configure `insecure-registries` (Docker) ou o `registries.yaml` (containerd do nó).
- **Pod em `ErrImagePull`/`ImagePullBackOff` puxando do registry** — confiança do containerd ainda não ativada; rode o playbook do k3s (`make k3s`) no host.

## Adoção no gh-eva

O primeiro consumidor é o `gh-eva`, cujo Deployment roda no namespace `gh-eva`. **A mudança abaixo ainda não foi aplicada**: o repositório do `gh-eva` não está nesta máquina e esta seção é a especificação do diff a aplicar em `deploy/gh-eva-api-k3s-local.sh`.

Remover do script:

- `docker save` da imagem construída;
- `mktemp` do diretório/tarball de transferência;
- o manifesto do Pod `gh-eva-api-image-import` (privilegiado, com `hostPath` do socket do containerd);
- o `kubectl cp` do tarball para o Pod;
- o `kubectl exec` com `ctr images import`;
- o `trap` de limpeza do Pod de import.

Adicionar/trocar no script:

- tag da imagem no padrão do registry, sem porta:

  ```bash
  TAG="registry.guiosoft.info/gh-eva/gh-eva-api:k3s-$(date +%Y%m%d%H%M%S)"
  ```

- `docker push "$TAG"` logo após o build;
- criação idempotente do Secret de pull pelo próprio script — `gh-eva-registry`, `type: kubernetes.io/dockerconfigjson` (o que `kubectl create secret docker-registry` gera), no mesmo padrão que o script já usa para `GH_EVA_API_SEND_KEY` (valor vindo de variável de ambiente, nunca commitado):

  ```bash
  kubectl -n gh-eva create secret docker-registry gh-eva-registry \
    --docker-server=registry.guiosoft.info \
    --docker-username=puller \
    --docker-password="${GH_EVA_REGISTRY_PASSWORD}" \
    --dry-run=client -o yaml | kubectl -n gh-eva apply -f -
  ```

  com `GH_EVA_REGISTRY_PASSWORD` alimentado pela saída de `bash scripts/registry-credentials.sh password puller` (neste repositório) no ambiente de quem executa o deploy;
- no manifesto do Deployment, a imagem passa a ser `registry.guiosoft.info/gh-eva/gh-eva-api:k3s-<timestamp>` e o template ganha:

  ```yaml
  imagePullSecrets:
    - name: gh-eva-registry
  ```

O Secret criado pelo `registry.sh validate` (`registry-pull-test`) segue exatamente esse formato e serve de referência. A adoção só fecha de ponta a ponta depois que o playbook do k3s ativar a confiança do containerd (passo pendente listado no diagnóstico).

## Fontes

- Zot — documentação oficial: https://zotregistry.dev/
- Zot — retenção e GC: https://zotregistry.dev/latest/articles/retention/
- K3s — Registry Mirror (`registries.yaml`): https://docs.k3s.io/installation/registry-mirror
- Docker — `insecure-registries`: https://docs.docker.com/engine/daemon/configuration/
- Kubernetes — `imagePullSecrets`: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
