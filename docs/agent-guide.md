# Guia para agentes — K3s Lab

Instruções operacionais para agentes de IA que trabalham com o cluster K3s `guiosoft-info`. Cobre deploy de serviços, exposição de subdomínios, uso do registry OCI e padrões de imagem.

## Visão geral

- **Cluster**: K3s single-node, `guiosoft-info` (Debian 13, `192.168.88.9`), k3s `v1.36.4+k3s1`
- **GitOps**: Flux reconcilia manifests de `guionardo/guiosoft-k3s-lab` (branch `main`)
- **Ingress**: Traefik (namespace `kube-system`), entrypoint `websecure` (443, certificado mkcert para LAN)
- **DNS público**: wildcard `*.guiosoft.info` → Cloudflare Tunnel → `http://192.168.88.9:80` (Traefik)
- **DNS LAN**: split-DNS no MikroTik aponta hostnames específicos para `192.168.88.9`
- **Registry OCI**: `https://registry.guiosoft.info` (Zot v2.1.22, LAN-only, cache descartável)
- **Secrets**: SOPS + age (chave privada no nó, nunca na estação)

## Publicar um serviço (deploy)

### 1. Criar o namespace

```bash
kubectl create namespace <app>
```

Ou declarar em `kubernetes/namespaces/<app>.yaml` e adicionar ao Flux.

### 2. Criar o Deployment

Padrão mínimo (exemplo em `kubernetes/apps/k3s-test/deployment.yaml`):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <app>
  namespace: <namespace>
  labels:
    app: <app>
spec:
  replicas: 1
  selector:
    matchLabels:
      app: <app>
  template:
    metadata:
      labels:
        app: <app>
    spec:
      containers:
        - name: <app>
          image: <imagem>
          imagePullPolicy: IfNotPresent  # ou Always para imagens do registry
          ports:
            - name: http
              containerPort: <porta>
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 20
```

Para imagens do registry (`registry.guiosoft.info/...`), usar `imagePullPolicy: Always` e adicionar:

```yaml
spec:
  imagePullSecrets:
    - name: <app>-registry
  containers:
    - name: <app>
      image: registry.guiosoft.info/<repo>/<app>:<tag>
      imagePullPolicy: Always
```

### 3. Criar o Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <app>
  namespace: <namespace>
spec:
  selector:
    app: <app>
  ports:
    - name: http
      port: <porta>
      targetPort: <porta>
```

### 4. Expor via Ingress (subdomínio)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <app>
  namespace: <namespace>
spec:
  ingressClassName: traefik
  rules:
    - host: <app>.guiosoft.info
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <app>
                port:
                  name: http
```

O subdomínio `<app>.guiosoft.info` é criado automaticamente: o wildcard DNS `*.guiosoft.info` já aponta para o Cloudflare Tunnel, que encaminha para o Traefik. O Traefik roteia para o Service com base no Ingress. **Não é necessário criar registro DNS individual** — basta criar o Ingress.

Para serviços LAN-only (bloqueados na internet), adicione a regra no Terraform (`terraform/cloudflare/main.tf`) antes do wildcard:

```hcl
{
  hostname = "<app>.guiosoft.info"
  service  = "http_status:404"
}
```

E configure split-DNS no MikroTik: `<app>.guiosoft.info -> 192.168.88.9`.

### 5. GitOps (Flux)

Adicione os manifests em `kubernetes/apps/<app>/` e referencie no `clusters/guiosoft-info/kustomization.yaml`:

```yaml
resources:
  - ../kubernetes/apps/<app>
```

O Flux reconcilia automaticamente. Para forçar: `flux reconcile kustomization <app>` (ou anote com `reconcile.fluxcd.io/requestedAt`).

## Publicar imagem no registry

### Push (a partir do nó)

O daemon Docker do nó precisa de `insecure-registries` configurado (ver `docs/registry.md`). O build deve rodar no nó (amd64 nativo).

```bash
# Obter senha do pusher
PW=$(bash scripts/registry-credentials.sh password pusher)

# Login
echo "$PW" | docker login registry.guiosoft.info -u pusher --password-stdin

# Build e push
TAG="registry.guiosoft.info/<repo>/<app>:k3s-$(date +%Y%m%d%H%M%S)"
docker build -t "$TAG" .
docker push "$TAG"
```

### Pull secret para Pods

```bash
kubectl -n <namespace> create secret docker-registry <app>-registry \
  --docker-server=registry.guiosoft.info \
  --docker-username=puller \
  --docker-password="$(bash scripts/registry-credentials.sh password puller)" \
  --dry-run=client -o yaml | kubectl -n <namespace> apply -f -
```

### Metadados da imagem (vendor e description)

**Toda imagem publicada deve incluir labels OCI de vendor e description.** Use no Dockerfile:

```dockerfile
LABEL org.opencontainers.image.vendor="Guiosoft"
LABEL org.opencontainers.image.description="Descrição curta do serviço"
LABEL org.opencontainers.image.source="https://github.com/guionardo/<repo>"
LABEL org.opencontainers.image.version="<versão ou tag>"
```

Ou via build-args:

```bash
docker build \
  --label "org.opencontainers.image.vendor=Guiosoft" \
  --label "org.opencontainers.image.description=Descrição do serviço" \
  --label "org.opencontainers.image.source=https://github.com/guionardo/<repo>" \
  -t "$TAG" .
```

Essas informações aparecem na UI do Zot (interface web) e são consultáveis via API:

```bash
curl -sk -u pusher:<senha> \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  https://registry.guiosoft.info/v2/<repo>/<app>/manifests/<tag>
```

### Verificação

```bash
make registry-validate          # 7 asserções
# ou
curl -sk -u pusher:<senha> https://registry.guiosoft.info/v2/_catalog
# UI web: https://registry.guiosoft.info/
```

## kubectl — padrões

- **Contexto**: o `kubectl` da estação aponta para o cluster via kubeconfig (ver `docs/remote-kubectl.md`).
- **Namespaces**: cada app tem seu próprio namespace. Secrets são separados por namespace sob `kubernetes/secrets/<app>/`.
- **Secrets SOPS**: cifrados com age, aplicados pelo Flux. Para operações manuais, descriptar via SSH no nó: `ssh guionardo@192.168.88.9 'cd ~/guiosoft-k3s-lab && sops --decrypt <arquivo>'`.
- **Rollout**: após mudar ConfigMap/Secret, reiniciar o Pod: `kubectl -n <ns> rollout restart deploy/<app>`.
- **Logs**: `kubectl -n <ns> logs deploy/<app> --tail=50`.
- **Status**: `kubectl -n <ns> get pods,svc,ingress`.

## Segurança

- **LAN-only**: serviços expostos apenas na LAN usam split-DNS + regra `http_status:404` no Cloudflare Tunnel antes do wildcard.
- **Default deny**: hostnames sem Ingress explícito recebem 404 do Traefik.
- **Secrets**: nunca commitar em claro. Usar SOPS + age. A chave privada age vive apenas no nó.
- **Registry**: cache descartável — imagens reconstruíveis do git. Nunca dependência de DR.

## Referências

- `docs/registry.md` — contrato operacional do registry
- `docs/networking.md` — DNS, Tunnel, Traefik
- `docs/architecture.md` — arquitetura do cluster
- `docs/gitops.md` — Flux e layout
- `docs/current-state.md` — estado atual do cluster
- `docs/roadmap.md` — fases e pendências