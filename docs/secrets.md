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
- the latest stable SOPS release from the official `getsops/sops` GitHub releases;
- an age identity for the administrative user, generated only when the identity file does not already exist.

Validate with:

```bash
age --version
sops --version
```

## Idempotent age identity bootstrap

Ansible owns the initial creation of the local age identity at:

```text
~/.config/sops/age/keys.txt
```

The identity is created with `age-keygen` only when that file is absent. The task uses Ansible's `creates` guard, so subsequent runs preserve the existing private key instead of rotating or replacing it.

Permissions are enforced as:

```text
~/.config/sops/age/           0700
~/.config/sops/age/keys.txt   0600
```

At the end of `make tools`, Ansible prints only the public `age1...` recipient and the path that must be backed up. The private `AGE-SECRET-KEY-...` material must never be copied into the repository or shared in command output.

Create an off-host backup of `~/.config/sops/age/keys.txt` before using it for irreplaceable secrets. Losing every private recipient makes the encrypted secrets unrecoverable.

If deliberate key rotation is required, it must be an explicit maintenance operation: create a new identity, add its public recipient to SOPS configuration, update/re-encrypt the affected files, verify decryption, and only then retire the old identity.

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
