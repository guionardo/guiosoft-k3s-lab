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

O split-DNS no MikroTik (`registry.guiosoft.info -> 192.168.88.9`) está configurado: estações que usam o DNS da LAN resolvem o hostname para o IP interno do nó, sem passar pelo Cloudflare. Máquinas fora desse DNS precisam de uma entrada própria — veja a seção de diagnóstico.

## Interface web

O Zot expõe uma interface web em `https://registry.guiosoft.info/` (raiz), habilitada via `extensions.ui` e `extensions.search` no ConfigMap `registry/registry-config`. Login com o mesmo htpasswd (`pusher`/`puller`). Lista repositórios, tags, manifests, camadas e o histórico de push/GC; útil para acompanhar a retenção sem usar a API. A extensão de busca cria um índice BadgerDB no PVC e indexa na inicialização — o primeiro start após habilitar pode levar ~40s.

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

A resolução fica a cargo do split-DNS do MikroTik; uma estação que não use o DNS da LAN precisa da entrada `192.168.88.9 registry.guiosoft.info` no próprio `/etc/hosts` para não cair na rota pública.

## Metadados OCI (vendor e description)

Toda imagem publicada deve incluir labels OCI de vendor e description. A UI do Zot exibe essas informações e elas são consultáveis via API.

No Dockerfile (stage final):

```dockerfile
LABEL org.opencontainers.image.vendor="Guiosoft"
LABEL org.opencontainers.image.title="<nome do servico>"
LABEL org.opencontainers.image.description="<descricao curta>"
LABEL org.opencontainers.image.source="https://github.com/guionardo/<repo>"
LABEL org.opencontainers.image.licenses="MIT"
```

Ou via build-args:

```bash
docker build \
  --label "org.opencontainers.image.vendor=Guiosoft" \
  --label "org.opencontainers.image.description=Descricao do servico" \
  --label "org.opencontainers.image.source=https://github.com/guionardo/<repo>" \
  -t "$TAG" .
```

Build, tag e push (o padrão de tag usado pela adoção do `gh-eva`):

```bash
TAG="registry.guiosoft.info/gh-eva/gh-eva-api:k3s-$(date +%Y%m%d%H%M%S)"
docker tag gh-eva-api:dev "$TAG"
docker push "$TAG"
```

## Tutorial: do zero ao primeiro push

Sequência mínima para publicar e consumir uma imagem, do estado vazio.

### 1. Confiança no certificado (autoassinado)

O Traefik usa o certificado padrão (autoassinado). O daemon do Docker da estação precisa confiar no host:

```json
// ~/.docker/daemon.json
{ "insecure-registries": ["registry.guiosoft.info"] }
```

Reinicie o Docker depois. No nó, a confiança é feita via `/etc/rancher/k3s/registries.yaml` (role Ansible `k3s`) para o containerd. O daemon Docker do nó (usado para build/push) precisa de uma entrada separada em `/etc/docker/daemon.json`:

```json
{ "insecure-registries": ["registry.guiosoft.info"] }
```

Crie o arquivo e reinicie o Docker (`sudo systemctl restart docker`). Sem isso, `docker push` falha com erro de TLS mesmo que o nó alcance o registry.

### 2. Resolução do hostname

Se a estação não usa o DNS da LAN, adicione em `/etc/hosts`:

```text
192.168.88.9 registry.guiosoft.info
```

### 3. Obter a senha do pusher

```bash
cd /caminho/do/guiosoft-k3s-lab
bash scripts/registry-credentials.sh password pusher
```

O script descripta o SOPS **no host** onde vive a chave age (via SSH). A chave privada nunca sai do nó. A senha tem 64 caracteres hex.

### 4. Login

```bash
make registry-login          # imprime o comando
docker login registry.guiosoft.info -u pusher
# cole a senha do passo 3
```

### 5. Build, tag e push

```bash
TAG="registry.guiosoft.info/<repo>/<app>:k3s-$(date +%Y%m%d%H%M%S)"
docker build -t "$TAG" .
docker push "$TAG"
```

O push devolve o digest `sha256:…`. Guarde-o se quiser reprodutibilidade.

### 6. Consumir no cluster

```bash
kubectl -n <namespace> create secret docker-registry registry-pull \
  --docker-server=registry.guiosoft.info \
  --docker-username=puller \
  --docker-password="$(bash scripts/registry-credentials.sh password puller)" \
  --dry-run=client -o yaml | kubectl -n <namespace> apply -f -
```

No Deployment:

```yaml
spec:
  imagePullSecrets:
    - name: registry-pull
  containers:
    - name: app
      image: registry.guiosoft.info/<repo>/<app>:k3s-<timestamp>
      imagePullPolicy: Always
```

### 7. Verificar

```bash
make registry-validate          # 7 asserções, termina em OK
# ou
curl -sk -u pusher:<senha> https://registry.guiosoft.info/v2/_catalog
# interface web: https://registry.guiosoft.info/  (login pusher)
```

Se as senhas forem regeradas (`generate`), aplique o Secret e reinicie o zot (`rollout restart`).

### Evidência: retenção exercitada

A retenção foi exercitada com uma sonda de 12 tags distintas no repositório `retention-probe-20261106114603`:

```text
antes do GC:  12 tags (v1..v12)
após restart do zot (GC no startup): 10 tags (v3..v12)
manifests v1, v2 -> HTTP 404   (evictados)
manifest v12    -> HTTP 200     (retido)
```

Confirma que o GC roda no startup do Pod, que `delay: 1h` não bloqueia a evicção de tags (afeta apenas untagged/referrers) e que as 10 mais recentemente pushed são mantidas. Os logs do zot registram cada decisão com `reason: retained by mostRecentlyPushedCount:10 policy`.

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

O containerd do nó confia no registry por meio de `/etc/rancher/k3s/registries.yaml` (mirror + `insecure_skip_verify` no bloco top-level `configs`) e de uma entrada em `/etc/hosts`, ambos codificados no role Ansible `k3s` e já aplicados no host: `make k3s` grava os arquivos, reinicia o k3s e o pull por Pod passa a funcionar. A asserção de pull do `validate` comprova isso imprimindo `pod pull (containerd): <imagem> pulled successfully`.

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

## Certificado TLS para o navegador (mkcert)

O Traefik usa o certificado autoassinado padrão, que o navegador não confia (e cujo SAN não inclui `registry.guiosoft.info`). Para eliminar o aviso de segurança e permitir que o navegador salve as credenciais, use o [mkcert](https://github.com/FiloSottile/mkcert):

```bash
brew install mkcert
mkcert -install                          # cria a CA local e adiciona ao trust store
mkcert registry.guiosoft.info            # gera registry.guiosoft.info.pem + -key.pem
```

Aplique no cluster:

```bash
kubectl -n registry create secret tls registry-tls \
  --cert=registry.guiosoft.info.pem --key=registry.guiosoft.info-key.pem
# o Ingress já referencia secretName: registry-tls (manifest em kubernetes/apps/registry/ingress.yaml)
kubectl -n registry rollout restart deploy/zot
```

O certificado tem validade de ~2,5 anos e pode ser renovado com o mesmo comando. Para outras máquinas na LAN, copie `$(mkcert -CAROOT)/rootCA.pem` e instale no trust store de cada uma.

O `insecure-registries` no daemon Docker do nó continua necessário para o `docker push` — o mkcert resolve apenas o navegador.

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

Com o split-DNS ativo e o playbook do k3s aplicado, o comportamento **esperado** é a validação completa, sem override:

```bash
bash scripts/registry.sh validate
```

Saída esperada, terminando em `Registry end-to-end validation: OK` com `exit 0`:

```text
resolution: registry.guiosoft.info -> 192.168.88.9 (OK)
public block: https://registry.guiosoft.info/v2/ -> 404 (via Cloudflare <ip>)
unauthenticated LAN: https://registry.guiosoft.info/v2/ -> 401
push/pull round trip: registry/smoke:smoke-<timestamp> (...) -> 201/200/200
pull as puller: registry/smoke:smoke-<timestamp> -> 200
warn: puller can push; read-only separation is not enforced by zot
pod pull (containerd): registry/smoke:smoke-<timestamp> pulled successfully
note: the smoke image is zero-layer with no command, so the pod is not expected to start; a successful pull is the pass criterion
```

A imagem de fumaça é zero-layer e sem `command`: o critério de PASS é o kubelet relatar o pull, não o Pod ficar `Ready`. Em estações que não usam o DNS da LAN, force o alvo do `--resolve`:

```bash
REGISTRY_RESOLVE_IP=192.168.88.9 bash scripts/registry.sh validate
```

Sintomas comuns:

- **`401` em `/v2/` sem credencial** — comportamento esperado; é a autenticação htpasswd. `401` no `docker login` significa credencial errada; se as senhas foram regeradas com `generate`, aplique o Secret e reinicie o zot (`rollout restart`).
- **`404 page not found` no push/pull** — quase sempre o hostname resolveu para a rota pública: Cloudflare -> Tunnel -> Traefik:80, e o Ingress só responde no `websecure`. Confirme a resolução na estação (`getent hosts registry.guiosoft.info` deve retornar `192.168.88.9`); se a estação não usa o DNS da LAN, use a entrada em `/etc/hosts`. Um hostname errado sem Ingress também recebe `404` do Traefik (default deny por ausência de rota).
- **erro x509/certificado** — o cliente não confia no certificado autoassinado; configure `insecure-registries` (Docker) ou o `registries.yaml` (containerd do nó).
- **Pod em `ErrImagePull`/`ImagePullBackOff` puxando do registry** — a confiança do containerd já está ativa; confira se o `registries.yaml` continua presente no nó (`sudo cat /etc/rancher/k3s/registries.yaml`) e se o hostname resolve para `192.168.88.9` dentro do nó (`grep registry.guiosoft.info /etc/hosts`). Se o arquivo sumiu, reaplique com `make k3s`.

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
