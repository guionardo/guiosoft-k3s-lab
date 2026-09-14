# Kubernetes secrets

Only SOPS-encrypted manifests belong in this directory.

Secrets managed by Flux are scoped by application so each Flux Kustomization owns only the Secrets for its own namespace/workload:

```text
kubernetes/secrets/
├── cloudflare/
│   ├── kustomization.yaml
│   └── cloudflared-token.sops.yaml
└── firecrawl/
    ├── kustomization.yaml
    └── firecrawl-secrets.sops.yaml
```

Do not add a root `kustomization.yaml` that combines unrelated application Secrets.

## Flux-compatible SOPS format

Kubernetes object structure must remain readable by Kustomize. Encrypt only Secret payload fields:

```bash
sops --encrypt \
  --encrypted-regex '^(data|stringData)$' \
  secret.yaml > secret.sops.yaml
```

`apiVersion`, `kind`, `metadata`, namespace and Secret name remain readable; values under `data` or `stringData` are encrypted.

The private age identity is not stored in Git. Flux receives it at runtime through the `flux-system/sops-age` Secret.

## Generic workflow

Create or edit an encrypted manifest:

```bash
make secret-edit FILE=kubernetes/secrets/<app>/example.sops.yaml
```

Inspect decrypted content without writing plaintext to disk:

```bash
make secret-view FILE=kubernetes/secrets/<app>/example.sops.yaml
```

Validate the decrypted manifest with kubectl client-side dry-run:

```bash
make secret-validate FILE=kubernetes/secrets/<app>/example.sops.yaml
```

Apply it directly without creating a plaintext file when manual recovery is required:

```bash
make secret-apply FILE=kubernetes/secrets/<app>/example.sops.yaml
```

Normal operation should let Flux reconcile the encrypted file rather than applying it manually.

## Application helpers

Firecrawl:

```bash
bash scripts/firecrawl-secret-from-env.sh /path/to/firecrawl/.env
```

Default output:

```text
kubernetes/secrets/firecrawl/firecrawl-secrets.sops.yaml
```

Cloudflare Tunnel:

```bash
bash scripts/cloudflared-token-secret.sh
```

Default output:

```text
kubernetes/secrets/cloudflare/cloudflared-token.sops.yaml
```

Both helpers avoid persisting plaintext Secret manifests and encrypt only `data`/`stringData` for Flux/Kustomize compatibility.
