# Secrets management

The homelab uses SOPS with age for secrets that must be stored in Git.

## Rules

- Never commit an age private identity, Cloudflare API token, tunnel token, kubeconfig, Terraform state, unencrypted `.tfvars`, database credentials, or other plaintext credentials.
- Public age recipients may be committed because they cannot decrypt secrets.
- Files intended for Git use the suffix `.sops.yaml`, `.sops.json`, `.sops.env`, or another SOPS-supported structured format.
- The age private identity belongs outside this repository and must have an off-host recovery copy.
- A second recovery recipient should be added before production-critical secrets depend on SOPS.

## Host tooling

`make tools` installs:

- Terraform;
- age from Debian packages;
- the latest stable SOPS release from the official `getsops/sops` GitHub releases.

Validate with:

```bash
age --version
sops --version
```

## Initial key bootstrap

Key generation is deliberately **not** automated by Ansible. Re-running bootstrap must never silently replace or create a new encryption identity.

Create the identity once as the normal administrative user:

```bash
mkdir -p ~/.config/sops/age
chmod 700 ~/.config/sops ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

Record the printed `age1...` public recipient. The `AGE-SECRET-KEY-...` identity must never be committed.

Create an off-host backup of `~/.config/sops/age/keys.txt` before using it for irreplaceable secrets.

## Repository configuration

After the initial recipient exists, add `.sops.yaml` at the repository root with a creation rule for files such as `*.sops.yaml`:

```yaml
creation_rules:
  - path_regex: .*\.sops\.ya?ml$
    age:
      - age1REPLACE_WITH_PUBLIC_RECIPIENT
```

Do not commit the placeholder. Commit `.sops.yaml` only after replacing it with the real **public** recipient.

## Typical workflow

Create or edit an encrypted secret:

```bash
sops kubernetes/secrets/example.sops.yaml
```

Inspect decrypted content without creating a plaintext file:

```bash
sops decrypt kubernetes/secrets/example.sops.yaml
```

When recipients change, update encrypted files with `sops updatekeys` and rotate the data key when appropriate.

## Kubernetes

SOPS is initially the encryption format and source-of-truth mechanism only. We will choose the in-cluster/GitOps decryption integration when the GitOps phase is implemented. Until then, avoid committing plaintext Kubernetes Secret manifests.
