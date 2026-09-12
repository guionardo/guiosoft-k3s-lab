# Kubernetes secrets

Only SOPS-encrypted manifests belong in this directory.

Trackable files:

- `README.md`
- `*.sops.yaml`

Plaintext secret manifests are intentionally ignored by Git.

## Workflow

Create or edit an encrypted manifest:

```bash
make secret-edit FILE=kubernetes/secrets/example.sops.yaml
```

Inspect decrypted content without writing plaintext to disk:

```bash
make secret-view FILE=kubernetes/secrets/example.sops.yaml
```

Validate the decrypted manifest with kubectl client-side dry-run:

```bash
make secret-validate FILE=kubernetes/secrets/example.sops.yaml
```

Apply it directly to the cluster without creating a plaintext file:

```bash
make secret-apply FILE=kubernetes/secrets/example.sops.yaml
```

The helper refuses paths outside `kubernetes/secrets/*.sops.yaml`.

A typical Kubernetes Secret edited through SOPS looks like this before encryption:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: example
  namespace: lab
type: Opaque
stringData:
  username: replace-me
  password: replace-me
```

After saving through SOPS, secret values are encrypted and the SOPS metadata is added to the file. Do not create or commit a plaintext copy alongside it.
