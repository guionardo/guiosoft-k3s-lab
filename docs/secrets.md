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

The repository root contains `.sops.yaml` with the public age recipient used for new encrypted YAML files matching `*.sops.yaml`.

The recipient is public metadata. The private age identity is never stored in Git.

## Round-trip validation

Validate local SOPS + age operation without persisting plaintext:

```bash
make secrets-test
```

The test creates temporary plaintext, encrypts it using `.sops.yaml`, decrypts it with the local age identity, compares both contents, and removes the temporary files.

## Kubernetes workflow

Encrypted Kubernetes Secret manifests live under:

```text
kubernetes/secrets/*.sops.yaml
```

The Git ignore rules allow only encrypted `*.sops.yaml` files and `README.md` in that directory.

Create or edit a secret directly through the SOPS editor:

```bash
make secret-edit FILE=kubernetes/secrets/example.sops.yaml
```

SOPS can create a new encrypted file from the configured creation rule, so there is no need to create a persistent plaintext precursor.

Inspect decrypted content on stdout:

```bash
make secret-view FILE=kubernetes/secrets/example.sops.yaml
```

Validate the decrypted Kubernetes manifest without changing the cluster:

```bash
make secret-validate FILE=kubernetes/secrets/example.sops.yaml
```

Apply it directly to Kubernetes without writing a decrypted file:

```bash
make secret-apply FILE=kubernetes/secrets/example.sops.yaml
```

The helper refuses files outside `kubernetes/secrets/*.sops.yaml` to reduce the chance of accidentally handling unrelated plaintext as a secret.

Until GitOps is implemented, `secret-apply` is the explicit bridge between encrypted Git state and the live cluster. Later, the chosen GitOps controller will own in-cluster decryption/reconciliation.

## Key changes and rotation

When recipients change, update encrypted files with `sops updatekeys` and rotate the data key when appropriate.

Do not retire an old private identity until all affected files have been rewrapped for the new recipient and decryption has been tested.
