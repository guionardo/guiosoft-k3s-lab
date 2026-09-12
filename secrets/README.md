# Infrastructure secrets

This directory may contain only SOPS-encrypted `*.sops.yaml` files.

Never commit plaintext credentials, Restic passwords, Cloudflare R2 Secret Access Keys, age private identities, API tokens, or generated runtime files.

For the R2 off-host backup workflow, create the encrypted file locally with:

```bash
make restic-r2-secret
```

The helper prompts for the R2 S3 Access Key ID, Secret Access Key and a new Restic repository password without echoing secret values. Plaintext exists only in a temporary file which is removed when the helper exits. The resulting `secrets/restic-r2.sops.yaml` is encrypted with the repository's configured age recipient.

Install the decrypted runtime material under `/etc/k3s-backup` with:

```bash
make restic-r2-install
```

Decryption occurs as the normal administrative user so the existing age identity can be used. Only the final root-owned files are installed with mode `0600`.
