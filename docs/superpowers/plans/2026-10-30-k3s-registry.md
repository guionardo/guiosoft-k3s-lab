# Registry OCI LAN-only no K3s — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publicar e consumir imagens OCI por `docker push`/pull a partir da LAN, sem `hostPath` no socket do containerd e sem expor o registry na internet.

**Architecture:** Zot roda em `registry` com PVC `local-path` e é servido pelo Traefik em `registry.guiosoft.info:443` com o certificado autoassinado padrão e clientes `insecure`. O Cloudflare Tunnel bloqueia o hostname com `http_status:404` antes do wildcard, e o containerd do node recebe `registries.yaml` + entrada em `/etc/hosts` via Ansible. O PVC é cache descartável e fica fora do snapshot restic de PVs.

**Tech Stack:** K3s v1.36.4+k3s1, Flux, SOPS+age, Traefik (bundle do K3s), Zot v2.1.22, restic, Prometheus Operator, Terraform (provider Cloudflare v5).

**Spec:** `docs/superpowers/specs/2026-10-30-k3s-registry-design.md`

## Global Constraints

- Imagem do registry: `ghcr.io/project-zot/zot:v2.1.22@sha256:96cda11459ce6f8c60da3b03f03e9f67fd11b3ae2d82c4c04c92b3c608996080`
- Hostname: `registry.guiosoft.info` — sem porta em nenhuma referência de imagem.
- Porta interna do Zot: `5000`. Ingress: `ingressClassName: traefik`, porta `443`, sem `secretName` (certificado padrão do Traefik).
- Namespace: `registry`. PVC: `20Gi`, `storageClassName: local-path`, nome `registry-data`.
- Usuários htpasswd: `pusher` (humano, push+pull) e `puller` (pods, read-only se o Zot permitir).
- Retenção: 10 tags mais recentes por repositório, `gc: true`.
- Node: `192.168.88.9`. PV root: `/mnt/store1/k3s/local-path`.
- Nenhum recurso `privileged`, nenhum `hostPath` de socket, nenhuma mudança em `/etc/rancher/k3s/config.yaml`.
- Toda imagem de workload continua pinada por digest; nenhum `:latest`.
- Flux não gerencia host nem K3s: `registries.yaml`, `/etc/hosts` e `HelmChartConfig` são do Ansible.

## Review Focus

1. **Estação da LAN sem split-DNS** resolve `registry.guiosoft.info` para IP público do Cloudflare; o push vai para o Tunnel, volta 404 e a mensagem parece "registry quebrado". Esperado: erro explícito antes do push, dizendo que a resolução não aponta para `192.168.88.9`. Teste na Task 7.
2. **PVC recriado** muda o diretório `pvc-<uuid>` e a exclusão literal do backup deixaria de casar em silêncio. Esperado: exclusão calculada do `claimRef` vivo, provada por `--dry-run`. Teste na Task 8.
3. **`registries.yaml` malformado** impede o containerd de subir — em single-node isso derruba o cluster inteiro, não só pulls. Esperado: validação de parse antes do restart e cópia de rollback. Teste na Task 6.
4. **Push de layer grande** estourando `respondingTimeouts` do Traefik: o push falha no meio e o erro do Docker não menciona timeout de ingress. Esperado: push de imagem com layer de ~200 MB concluindo. Teste na Task 6/7.
5. **Credencial de pull com poder de push**: um workload comprometido reescreve a imagem que outros consomem. Esperado: push autenticado como `puller` rejeitado. Teste na Task 7, com registro explícito da dívida se o Zot não impuser.

---

### Task 1: Bloqueio público no Cloudflare

Protege o hostname antes que qualquer Ingress exista. `registry.guiosoft.info` hoje resolve para IPs públicos pelo wildcard.

**Files:**
- Modify: `terraform/cloudflare/main.tf` (bloco `ingress` do `cloudflare_zero_trust_tunnel_cloudflared_config.homelab`)

**Interfaces:**
- Consumes: nada.
- Produces: regra `registry.guiosoft.info -> http_status:404` posicionada antes do wildcard, que a Task 7 verifica.

- [ ] **Step 1: Registrar o baseline do plano**

```bash
cd terraform/cloudflare && terraform plan -input=false -no-color | tail -5
```

Esperado: `No changes. Your infrastructure matches the configuration.` Se houver drift, parar e resolver antes de continuar.

- [ ] **Step 2: Adicionar a regra antes do wildcard**

Inserir como primeiro elemento da lista `ingress`, imediatamente antes do bloco do Firecrawl:

```hcl
      # Registry is LAN-only. Like Firecrawl, this rule must precede the
      # wildcard: the DNS record for *.guiosoft.info still points here, so
      # without it the registry would be reachable from the internet as soon
      # as its Traefik Ingress reconciles.
      {
        hostname       = "registry.guiosoft.info"
        service        = "http_status:404"
        origin_request = {}
      },
```

- [ ] **Step 3: Validar formatação e sintaxe**

```bash
make tf-cloudflare-fmt && make tf-cloudflare-validate
```

Esperado: `Success! The configuration is valid.`

- [ ] **Step 4: Revisar o plano**

```bash
make tf-cloudflare-plan
```

Esperado: exatamente uma alteração, do tipo *update in-place* em `cloudflare_zero_trust_tunnel_cloudflared_config.homelab`; nenhum recurso destruído; a ordem do `ingress` mostra `registry` antes de `*.guiosoft.info`.

- [ ] **Step 5: Aplicar (passo humano, com confirmação explícita)**

```bash
cd terraform/cloudflare && terraform apply
```

Esperado: `Apply complete! Resources: 0 added, 1 changed, 0 destroyed.`

- [ ] **Step 6: Verificar o bloqueio externo**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://registry.guiosoft.info/v2/
```

Esperado: `404`. (Ainda não há registro público servindo nada; este 404 vem do Tunnel.)

- [ ] **Step 7: Commit**

```bash
git add terraform/cloudflare/main.tf
git commit -m "feat(cloudflare): block registry.guiosoft.info at the tunnel"
```

---

### Task 2: Namespace e wiring do Flux

**Files:**
- Create: `kubernetes/namespaces/registry/namespace.yaml`
- Create: `kubernetes/namespaces/registry/kustomization.yaml`
- Create: `clusters/guiosoft-info/registry-namespace.yaml`
- Modify: `clusters/guiosoft-info/kustomization.yaml`

**Interfaces:**
- Consumes: nada.
- Produces: namespace `registry`; Kustomization Flux `registry-namespace`, da qual a Task 3 depende e a Task 4 referencia em `dependsOn`.

- [ ] **Step 1: Escrever o namespace**

`kubernetes/namespaces/registry/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: registry
  labels:
    app.kubernetes.io/part-of: registry
```

`kubernetes/namespaces/registry/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
```

- [ ] **Step 2: Escrever o Kustomization do Flux**

`clusters/guiosoft-info/registry-namespace.yaml`, no formato de `planetapeia-namespace.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: registry-namespace
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  timeout: 1m
  wait: true
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./kubernetes/namespaces/registry
```

- [ ] **Step 3: Registrar no kustomization raiz**

Adicionar `- registry-namespace.yaml` à lista `resources` de `clusters/guiosoft-info/kustomization.yaml`, mantendo ordem alfabética com as entradas existentes.

- [ ] **Step 4: Verificar o build**

```bash
kubectl kustomize kubernetes/namespaces/registry && kubectl kustomize clusters/guiosoft-info >/dev/null && echo OK
```

Esperado: `OK` e o Namespace `registry` no output do primeiro comando.

- [ ] **Step 5: Aplicar e confirmar**

```bash
kubectl apply -k kubernetes/namespaces/registry
kubectl get ns registry -o jsonpath='{.metadata.name}{"\n"}'
```

Esperado: `registry`.

- [ ] **Step 6: Commit**

```bash
git add kubernetes/namespaces/registry clusters/guiosoft-info/registry-namespace.yaml clusters/guiosoft-info/kustomization.yaml
git commit -m "feat(registry): add namespace and flux wiring"
```

---

### Task 3: Credencial htpasswd e Secret SOPS

**Files:**
- Create: `scripts/registry-credentials.sh`
- Create: `kubernetes/secrets/registry/kustomization.yaml`
- Create: `kubernetes/secrets/registry/registry-htpasswd.sops.yaml` (gerado, cifrado)
- Create: `clusters/guiosoft-info/registry-secrets.yaml`
- Modify: `clusters/guiosoft-info/kustomization.yaml`

**Interfaces:**
- Consumes: namespace `registry` (Task 2).
- Produces: Secret `registry/registry-htpasswd`, chave `htpasswd`, com usuários `pusher` e `puller`; Kustomization Flux `registry-secrets`; subcomandos `generate`, `validate`, `login` do script.

- [ ] **Step 1: Escrever o script de credencial**

`scripts/registry-credentials.sh`, `set -euo pipefail`, no estilo dos scripts existentes (mensagens `error:` em stderr, `exit 2` para uso incorreto). Subcomandos:

- `generate` — gera senhas aleatórias para `pusher` e `puller` com `openssl rand -hex 32`, produz o arquivo htpasswd com `htpasswd -nbB <user> <pass>`, monta em memória o manifesto `Secret` (`type: Opaque`, `stringData: {htpasswd: ...}`) e grava `kubernetes/secrets/registry/registry-htpasswd.sops.yaml` via `sops --encrypt --encrypted-regex '^(data|stringData)$'`. Nunca imprime as senhas.
- `validate` — falha se o usuário `pusher` ou `puller` não existir no arquivo decifrado; valida com `make secret-validate FILE=...`.
- `login` — imprime apenas o comando `docker login registry.guiosoft.info -u pusher`.
- `password <user>` — imprime somente a senha em stdout, para uso em pipes (`docker login --password-stdin`). Nunca imprime a senha junto de log ou mensagem.

- [ ] **Step 2: Verificar que falha sem artefato**

```bash
bash scripts/registry-credentials.sh validate
```

Esperado: falha com mensagem de arquivo ausente e código de saída não-zero.

- [ ] **Step 3: Gerar o Secret cifrado**

```bash
bash scripts/registry-credentials.sh generate
bash scripts/registry-credentials.sh validate
```

Esperado: `registry-htpasswd.sops.yaml` criado, sem texto claro de senha em nenhum arquivo do repositório; `validate` retorna 0.

- [ ] **Step 4: Confirmar que só o payload está cifrado**

```bash
grep -E '^(apiVersion|kind|type):' kubernetes/secrets/registry/registry-htpasswd.sops.yaml
```

Esperado: `apiVersion: v1`, `kind: Secret`, `type: Opaque` legíveis (não `ENC[`).

- [ ] **Step 5: Ligar ao Flux**

`kubernetes/secrets/registry/kustomization.yaml` lista `registry-htpasswd.sops.yaml`.
`clusters/guiosoft-info/registry-secrets.yaml` espelha `planetapeia-secrets.yaml`: `path: ./kubernetes/secrets/registry`, `decryption.provider: sops`, `secretRef.name: sops-age`, `dependsOn: registry-namespace`. Registrar no kustomization raiz.

- [ ] **Step 6: Verificar sync**

```bash
kubectl -n registry get secret registry-htpasswd -o jsonpath='{.data.htpasswd}' | base64 -d | cut -d: -f1
```

Esperado: imprime `pusher` e `puller`, uma por linha. Se o Secret ainda não existir, aguardar a reconciliação (intervalo de 10m) e repetir.

- [ ] **Step 7: Commit**

```bash
git add scripts/registry-credentials.sh kubernetes/secrets/registry clusters/guiosoft-info/registry-secrets.yaml clusters/guiosoft-info/kustomization.yaml
git commit -m "feat(registry): add htpasswd credentials as sops secret"
```

---

### Task 4: Manifestos do Zot

**Files:**
- Create: `kubernetes/apps/registry/pvc.yaml`
- Create: `kubernetes/apps/registry/configmap.yaml`
- Create: `kubernetes/apps/registry/deployment.yaml`
- Create: `kubernetes/apps/registry/service.yaml`
- Create: `kubernetes/apps/registry/kustomization.yaml`
- Create: `clusters/guiosoft-info/registry.yaml`
- Modify: `clusters/guiosoft-info/kustomization.yaml`

**Interfaces:**
- Consumes: namespace `registry` (Task 2), Secret `registry-htpasswd` (Task 3).
- Produces: Service `registry/zot` porta `5000` nome `http`; PVC `registry/registry-data`; Deployment `registry/zot`.

- [ ] **Step 1: PVC**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-data
  namespace: registry
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 20Gi
```

- [ ] **Step 2: ConfigMap do Zot**

`config.json` dentro do ConfigMap `registry-config`, chave `config.json`:

```json
{
  "distSpecVersion": "1.1.0",
  "storage": {
    "rootDirectory": "/var/lib/registry",
    "gc": true,
    "gcInterval": "24h",
    "retention": {
      "delay": "1h",
      "policies": [
        {
          "repositories": ["**"],
          "deleteReferrers": false,
          "keepTags": [
            { "patterns": [".*"], "mostRecentlyPushedCount": 10 }
          ]
        }
      ]
    }
  },
  "http": {
    "address": "0.0.0.0",
    "port": "5000",
    "auth": { "htpasswd": { "path": "/etc/zot/htpasswd" } }
  },
  "log": { "level": "info" }
}
```

- [ ] **Step 3: Deployment e Service**

Deployment `zot`, `replicas: 1`, `strategy: Recreate` (PVC `ReadWriteOnce`), container `zot` com a imagem do Global Constraints, containerPort `5000` nome `http`, `readinessProbe` HTTP GET `/v2/` em `5000`, `resources.requests {cpu: 50m, memory: 64Mi}`, `limits {memory: 256Mi}`, `securityContext` do container com `allowPrivilegeEscalation: false` e `capabilities.drop: ["ALL"]`, montagens: `registry-data` em `/var/lib/registry`, ConfigMap em `/etc/zot/config.json` (`subPath`), Secret `registry-htpasswd` em `/etc/zot` (`readOnly`, `defaultMode: 0400`).
Service `zot`, `ClusterIP`, porta `5000` nome `http` → targetPort `http`.

- [ ] **Step 4: Kustomization e Flux**

`kubernetes/apps/registry/kustomization.yaml` lista os quatro arquivos. `clusters/guiosoft-info/registry.yaml` espelha `planetapeia.yaml` com `path: ./kubernetes/apps/registry`, `wait: true`, health check de PVC igual ao de `planetapeia.yaml`, e `dependsOn: [registry-secrets]`. Registrar no kustomization raiz.

- [ ] **Step 5: Verificar o build e o dry-run do servidor**

```bash
kubectl kustomize kubernetes/apps/registry >/dev/null && kubectl apply -k kubernetes/apps/registry --dry-run=server
```

Esperado: nenhum erro; quatro objetos listados.

- [ ] **Step 6: Aplicar e confirmar**

```bash
kubectl apply -k kubernetes/apps/registry
kubectl -n registry rollout status deploy/zot --timeout=180s
kubectl -n registry get pvc registry-data -o jsonpath='{.status.phase}{"\n"}'
```

Esperado: `deployment "zot" successfully rolled out` e `Bound`.

Se o Pod falhar por permissão no volume, o ajuste é `securityContext.fsGroup: 1000` no Pod — não montar `hostPath` nem usar `privileged`.

- [ ] **Step 7: Commit**

```bash
git add kubernetes/apps/registry clusters/guiosoft-info/registry.yaml clusters/guiosoft-info/kustomization.yaml
git commit -m "feat(registry): deploy zot with local cache pvc"
```

---

### Task 5: Ingress em 443 com TLS do Traefik

**Files:**
- Create: `kubernetes/apps/registry/ingress.yaml`
- Modify: `kubernetes/apps/registry/kustomization.yaml`

**Interfaces:**
- Consumes: Service `registry/zot` porta `http` (Task 4).
- Produces: endpoint `https://registry.guiosoft.info/v2/` respondendo do node.

- [ ] **Step 1: Escrever o Ingress**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: registry
  namespace: registry
  annotations:
    # The Cloudflare Tunnel wildcard origin is the node's port 80. Without this
    # pin, the Ingress also matches on the `web` entrypoint and the registry is
    # reachable from the internet even before the Tunnel deny rule is applied.
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts: [registry.guiosoft.info]
  rules:
    - host: registry.guiosoft.info
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: zot
                port:
                  name: http
```

Sem `secretName`: o Traefik usa o certificado autoassinado padrão. Os clientes são `insecure`, então a verificação é desligada dos dois lados.

- [ ] **Step 2: Aplicar e verificar sem depender de DNS**

```bash
kubectl apply -k kubernetes/apps/registry
curl -sk --resolve registry.guiosoft.info:443:192.168.88.9 -o /dev/null -w '%{http_code}\n' https://registry.guiosoft.info/v2/
```

Esperado: `401` (autenticação exigida, TLS aceito). `404` aqui significa que o Ingress não casou com o host.

- [ ] **Step 3: Verificar com credencial**

```bash
p="$(bash scripts/registry-credentials.sh password pusher)"
curl -sk -u "pusher:$p" --resolve registry.guiosoft.info:443:192.168.88.9 -o /dev/null -w '%{http_code}\n' https://registry.guiosoft.info/v2/
```

Esperado: `200`.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/registry/ingress.yaml kubernetes/apps/registry/kustomization.yaml
git commit -m "feat(registry): expose zot on 443 behind traefik"
```

---

### Task 6: Containerd, `/etc/hosts` e timeouts do Traefik

Sem esta task, pods não puxam do registry e pushes grandes podem falhar. É a única task que reinicia o K3s.

**Files:**
- Modify: `ansible/roles/k3s/tasks/main.yml`
- Create: `ansible/roles/k3s/files/registries.yaml`
- Create: `ansible/roles/k3s/files/traefik-helmchartconfig.yaml`
- Modify: `ansible/roles/k3s/handlers/main.yml` (só se precisar do handler de Traefik)

**Interfaces:**
- Consumes: hostname e porta 443 (Task 5).
- Produces: `/etc/rancher/k3s/registries.yaml`, linha em `/etc/hosts`, `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml`.

- [ ] **Step 1: Escrever os arquivos gerenciados**

`ansible/roles/k3s/files/registries.yaml`:

```yaml
mirrors:
  registry.guiosoft.info:
    endpoint:
      - "https://registry.guiosoft.info"
configs:
  "registry.guiosoft.info":
    tls:
      insecure_skip_verify: true
```

TLS settings live under top-level `configs`, not inside a mirror entry: `mirrors.<registry>` accepts only `endpoint` and `rewrite`, so a nested `config:` block is silently ignored by containerd.

`ansible/roles/k3s/files/traefik-helmchartconfig.yaml`:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    additionalArguments:
      - "--entrypoints.web.transport.respondingTimeouts.readTimeout=0"
      - "--entrypoints.web.transport.respondingTimeouts.writeTimeout=0"
      - "--entrypoints.websecure.transport.respondingTimeouts.readTimeout=0"
      - "--entrypoints.websecure.transport.respondingTimeouts.writeTimeout=0"
```

- [ ] **Step 2: Adicionar as tasks e a validação pré-restart**

Em `ansible/roles/k3s/tasks/main.yml`, depois da task de `config.yaml`:

- task `ansible.builtin.copy` de `registries.yaml` para `/etc/rancher/k3s/registries.yaml` (root, `0600`), `notify: Restart k3s`;
- task `ansible.builtin.copy` do `traefik-helmchartconfig.yaml` para `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml` (root, `0644`), `notify: Restart k3s`;
- task `ansible.builtin.lineinfile` em `/etc/hosts` com `line: "192.168.88.9 registry.guiosoft.info"` e `regexp: '^192\.168\.88\.9 registry\.guiosoft\.info$'`, sem handler;
- task de validação **antes** dos handlers: `ansible.builtin.command` rodando
  `python3 -c "import yaml,sys; yaml.safe_load(open('/etc/rancher/k3s/registries.yaml'))"`
  com `changed_when: false` e `failed_when: rc != 0`, garantindo parse válido antes de qualquer restart.

- [ ] **Step 3: Rodar o playbook**

```bash
make k3s
```

Esperado: `changed` na cópia do `registries.yaml`, handler `Restart k3s` executado, task de readiness do API passando ao final.

- [ ] **Step 4: Confirmar estado no host**

```bash
ssh guionardo@192.168.88.9 'sudo cat /etc/rancher/k3s/registries.yaml; getent hosts registry.guiosoft.info; sudo kubectl get nodes'
```

Esperado: o YAML esperado, `192.168.88.9 registry.guiosoft.info`, node `Ready`.

- [ ] **Step 5: Confirmar que o Traefik aceitou a configuração**

```bash
kubectl -n kube-system get helmchartconfig traefik -o jsonpath='{.spec.valuesContent}' | head -3
```

Esperado: os quatro `additionalArguments`.

- [ ] **Step 6: Confirmar que o containerd incorporou o mirror**

```bash
ssh guionardo@192.168.88.9 'sudo cat /var/lib/rancher/k3s/agent/etc/containerd/certs.d/registry.guiosoft.info/hosts.toml'
```

Esperado: `server = "https://registry.guiosoft.info"` e `skip_verify = true`. K3s materializa o `registries.yaml` como `hosts.toml` por registry em `certs.d/`; se o diretório não existir, o fallback é procurar o host em `/var/lib/rancher/k3s/agent/etc/containerd/config.toml`. Ausência nos dois significa que o `registries.yaml` não foi lido — o restart não ocorreu ou o arquivo está no caminho errado. O pull autenticado a partir do node é verificado na Task 7.

- [ ] **Step 7: Commit**

```bash
git add ansible/roles/k3s
git commit -m "feat(k3s): trust lan registry in containerd and raise traefik timeouts"
```

---

### Task 7: Validação ponta a ponta

**Files:**
- Create: `scripts/registry.sh`
- Modify: `Makefile` (alvos `registry-status`, `registry-validate`, `registry-login`)

**Interfaces:**
- Consumes: tudo das tasks 1–6; `scripts/registry-credentials.sh login` (Task 3).
- Produces: `bash scripts/registry.sh status|validate`; alvos `make registry-*`.

- [ ] **Step 1: Escrever as asserções que devem falhar**

`scripts/registry.sh validate` executa, nesta ordem, e sai não-zero no primeiro erro:

1. Resolução: `getent hosts registry.guiosoft.info` (ou `dig +short`) precisa retornar `192.168.88.9`. Se retornar IP público, falhar com `error: registry.guiosoft.info resolves publicly; add the MikroTik split-DNS entry`.
2. Bloqueio externo: `curl -s -o /dev/null -w '%{http_code}' --resolve registry.guiosoft.info:443:104.21.7.18 https://registry.guiosoft.info/v2/` precisa ser `404`.
3. Não autenticado: `curl -sk -o /dev/null -w '%{http_code}' --resolve registry.guiosoft.info:443:192.168.88.9 https://registry.guiosoft.info/v2/` precisa ser `401`.
4. Push/pull autenticado: build de imagem scratch (`FROM scratch` + arquivo de 1 byte), push para `registry.guiosoft.info/registry/smoke:<timestamp>`, pod `registry-pull-test` com `imagePullSecrets` e `imagePullPolicy: Always` alcançando `Ready`, depois limpeza do pod.
5. Push como `puller` precisa ser rejeitado. Se o Zot aceitar, o script imprime `warn:` e a Task 10 registra a dívida no documento em vez de falhar.

`status` imprime Deployment, PVC, Ingress e o estado do último push conhecido, no formato de `firecrawl-k8s.sh status`.

- [ ] **Step 2: Rodar e ver falhar**

```bash
bash scripts/registry.sh validate; echo "exit=$?"
```

Esperado: falha no item 1 (ainda sem split-DNS) com a mensagem de resolução, `exit=1`.

- [ ] **Step 3: Adicionar o split-DNS no MikroTik (passo humano)**

Criar o registro estático `registry.guiosoft.info -> 192.168.88.9`, igual ao do Firecrawl. Documentar em `docs/networking.md` no mesmo formato da entrada existente.

- [ ] **Step 4: Rodar de novo**

```bash
bash scripts/registry.sh validate; echo "exit=$?"
```

Esperado: `exit=0` com as cinco asserções aprovadas.

- [ ] **Step 5: Verificar push de layer grande**

```bash
docker build -t registry.guiosoft.info/registry/bigpush:probe -f - . <<'EOF'
FROM alpine:3.22
RUN dd if=/dev/urandom of=/big.bin bs=1M count=200
EOF
docker push registry.guiosoft.info/registry/bigpush:probe
```

Esperado: push completo sem timeout de ingress. Se falhar com timeout, a Task 6 não foi efetiva.

- [ ] **Step 6: Verificar o pull pelo containerd do node**

```bash
ssh guionardo@192.168.88.9 "sudo k3s ctr images pull --user pusher:$(bash scripts/registry-credentials.sh password pusher) registry.guiosoft.info/registry/smoke:probe"
```

Esperado: pull concluído sem erro de TLS nem `401`. Este é o único cliente que exercita o `registries.yaml` diretamente.

- [ ] **Step 7: Verificar a retenção e o GC**

Publicar 12 tags distintas em `registry/retention-probe` e forçar uma rodada de GC, aguardando o `gcInterval` configurado na Task 4 (ou reiniciando o Pod para disparar o GC de startup):

```bash
for i in $(seq 1 12); do docker tag registry.guiosoft.info/registry/smoke:probe registry.guiosoft.info/registry/retention-probe:t$i; docker push -q registry.guiosoft.info/registry/retention-probe:t$i; done
kubectl -n registry rollout restart deploy/zot && kubectl -n registry rollout status deploy/zot --timeout=120s
curl -sk -u "pusher:$(bash scripts/registry-credentials.sh password pusher)" https://registry.guiosoft.info/v2/registry/retention-probe/tags/list
```

Esperado: a lista contém no máximo 10 tags — as duas mais antigas foram coletadas. Se a lista mantiver 12, o schema de `retention` não foi aplicado: ajustar `config.json` conforme a versão do Zot e repetir.

- [ ] **Step 8: Adicionar os alvos do Makefile**

`registry-status` → `bash scripts/registry.sh status`; `registry-validate` → `bash scripts/registry.sh validate`; `registry-login` → `bash scripts/registry-credentials.sh login`. Incluir as três entradas no `.PHONY` e no texto do `help`, seguindo o padrão das linhas vizinhas.

- [ ] **Step 9: Commit**

```bash
git add scripts/registry.sh Makefile docs/networking.md
git commit -m "feat(registry): add end-to-end validation and make targets"
```

---

### Task 8: Exclusão do backup e asserção de DR

**Files:**
- Modify: `scripts/k3s-pv-backup-r2.sh`
- Modify: `scripts/dr-preflight.sh`

**Interfaces:**
- Consumes: PVC `registry/registry-data` (Task 4).
- Produces: `restic backup` com `--exclude` calculado do `claimRef`; preflight que falha se o PV do registry aparecer no rehearsal set.

- [ ] **Step 1: Escrever a resolução do diretório e a asserção**

Em `k3s-pv-backup-r2.sh`, antes do `restic backup`:

- resolver o PV de `-n registry get pvc registry-data -o jsonpath='{.spec.volumeName}'`;
- derivar o diretório como `$PV_ROOT/<namespace>_<claim>_<pv-uid>`; se o layout real divergir, derivar de `kubectl get pv <name> -o jsonpath='{.spec.local.path}'` — o caminho observado no host é a fonte de verdade;
- adicionar `--exclude "$REGISTRY_DIR"` ao `restic backup`;
- se o PVC não existir, seguir sem exclusão, imprimindo `registry cache PVC absent; nothing to exclude`.

Em `dr-preflight.sh`, assertar que o PV do registry não está entre os quatro do rehearsal set, com mensagem explícita em caso de presença.

- [ ] **Step 2: Provar a exclusão**

```bash
sudo K3S_PV_BACKUP_CONFIRM=backup-production-pvs restic backup --dry-run /mnt/store1/k3s/local-path --exclude "<dir do registry>" -v 2>&1 | grep -c registry
```

Esperado: `0` ocorrências de caminho do registry no output; e o script completo reporta `snapshot_id` normalmente.

- [ ] **Step 3: Provar a asserção de preflight**

```bash
bash scripts/dr-preflight.sh && echo OK
```

Esperado: `OK`, sem menção ao PV do registry na lista de volumes do rehearsal set.

- [ ] **Step 4: Commit**

```bash
git add scripts/k3s-pv-backup-r2.sh scripts/dr-preflight.sh
git commit -m "fix(backup): exclude disposable registry cache from pv snapshots"
```

---

### Task 9: Alerta de espaço em `/mnt/store1`

**Files:**
- Create: `kubernetes/apps/registry/registry-alerts.yaml`
- Modify: `kubernetes/apps/registry/kustomization.yaml`

**Interfaces:**
- Consumes: node-exporter do kube-prometheus-stack.
- Produces: `PrometheusRule registry/registry-storage`, com o alerta `K3sLocalPathLowFreeSpace`.

- [ ] **Step 1: Escrever o teste do alerta**

`kubernetes/apps/registry/registry-alerts.yaml`, no formato de `kubernetes/apps/otel-go-demo/prometheus-rules.yaml` (`labels.release: kube-prometheus-stack`):

```yaml
        - alert: K3sLocalPathLowFreeSpace
          expr: |
            node_filesystem_avail_bytes{mountpoint="/mnt/store1"}
            / node_filesystem_size_bytes{mountpoint="/mnt/store1"} < 0.15
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: /mnt/store1 is below 15% free
            description: Persistent volumes, including the registry cache, may fail to grow.
```

- [ ] **Step 2: Validar a expressão com dados sintéticos**

```bash
promtool test rules /dev/stdin <<'EOF'
rule_files: []
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      - series: 'node_filesystem_avail_bytes{mountpoint="/mnt/store1"}'
        values: '10 10 10 10 10 10 10 10 10 10 10 10 10 10 10 10'
      - series: 'node_filesystem_size_bytes{mountpoint="/mnt/store1"}'
        values: '100 100 100 100 100 100 100 100 100 100 100 100 100 100 100 100'
    alert_rule_test:
      - eval_time: 20m
        alertname: K3sLocalPathLowFreeSpace
        exp_alerts:
          - exp_labels:
              severity: warning
              mountpoint: /mnt/store1
EOF
```

Esperado: `SUCCESS`. Se `promtool` não estiver instalado, validar com `kubectl apply --dry-run=server -f kubernetes/apps/registry/registry-alerts.yaml` e registrar que o teste sintético ficou pendente.

- [ ] **Step 3: Aplicar e confirmar no Prometheus**

```bash
kubectl apply -k kubernetes/apps/registry
kubectl -n registry get prometheusrule registry-storage -o jsonpath='{.spec.groups[0].rules[0].alert}{"\n"}'
```

Esperado: `K3sLocalPathLowFreeSpace`.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/registry/registry-alerts.yaml kubernetes/apps/registry/kustomization.yaml
git commit -m "feat(registry): alert on low free space for persistent volumes"
```

---

### Task 10: Documentação e adoção pelo `gh-eva`

**Files:**
- Create: `docs/registry.md`
- Modify: `docs/roadmap.md`
- Modify: `docs/current-state.md`
- Modify: `docs/disaster-recovery.md`
- Modify: `docs/architecture.md`
- Out-of-repo: `deploy/gh-eva-api-k3s-local.sh` (repositório do `gh-eva`)

**Interfaces:**
- Consumes: tudo.
- Produces: documentação operacional e o diff do script consumidor.

- [ ] **Step 1: Escrever `docs/registry.md`**

Seções, no estilo dos documentos vizinhos: o que é e por que existe (substitui o `ctr import`); endereço e credenciais; como publicar (`make registry-login`, `docker push`); como consumir (`imagePullSecrets`); retenção e GC; o que acontece se o cache for perdido; por que não está no backup; como expor publicamente no futuro (certificado válido + remover `insecure-registries` + remover a regra 404 do Tunnel); diagnóstico (`401`, `404` de host errado, resolução pública).

- [ ] **Step 2: Atualizar os documentos existentes**

- `docs/roadmap.md`: nova fase com os itens concluídos, incluindo o registro da dívida caso a Task 7 tenha imprimido `warn:` sobre push com `puller`.
- `docs/current-state.md`: registry na tabela de workloads, com o PVC marcado como cache descartável.
- `docs/disaster-recovery.md`: parágrafo explícito de que o registry é excluído do snapshot de PV e que as imagens são reconstruídas do git.
- `docs/architecture.md`: o registry no diagrama de componentes.

- [ ] **Step 3: Descrever o diff do `gh-eva`**

No fim de `docs/registry.md`, uma seção "Adoção no gh-eva" com o diff exato: remover `docker save`, `mktemp`, o manifesto do pod `gh-eva-api-image-import`, o `hostPath` do socket, `kubectl cp`, `kubectl exec`, `ctr images import` e o `trap` de limpeza do pod; trocar a tag por `registry.guiosoft.info/gh-eva/gh-eva-api:k3s-<timestamp>`; adicionar `docker push` após o build; criar `gh-eva-registry` (`type: kubernetes.io/dockerconfigjson`) no namespace `gh-eva` pelo próprio script, no padrão de `GH_EVA_API_SEND_KEY`; adicionar `imagePullSecrets` ao Deployment.

- [ ] **Step 4: Verificar que a documentação não mente**

```bash
grep -n "registry.guiosoft.info" docs/*.md | wc -l
bash scripts/registry.sh validate && echo DOCS-OK
```

Esperado: contagem maior que zero e `DOCS-OK`. Cada comando citado em `docs/registry.md` deve ser copiável e executável.

- [ ] **Step 5: Commit**

```bash
git add docs/registry.md docs/roadmap.md docs/current-state.md docs/disaster-recovery.md docs/architecture.md
git commit -m "docs(registry): document lan registry, retention and dr exclusion"
```
