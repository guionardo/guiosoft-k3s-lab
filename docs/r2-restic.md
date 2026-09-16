# Restic off-host backup on Cloudflare R2

## Current decision

Cloudflare R2 is the selected off-host destination. The bucket `guiosoft-k3s-backups` is managed by the dedicated `terraform/r2` stack and has been created successfully.

The Restic repository will live under the `restic/` prefix of that bucket:

```text
s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/guiosoft-k3s-backups/restic
```

R2 exposes an S3-compatible API at the account endpoint. Restic supports non-AWS S3-compatible repositories using the `s3:https://server/bucket/path` form.

## Credential separation

Do not reuse the Cloudflare API token used by Terraform.

Create a dedicated R2 S3 credential with **Object Read & Write** and scope it only to `guiosoft-k3s-backups`. Cloudflare provides an Access Key ID and Secret Access Key for S3 clients.

The Restic repository password is a separate secret. Losing it makes the encrypted Restic repository unusable even if the R2 objects remain available.

## Create the encrypted configuration

After creating the bucket-scoped R2 S3 credential, run as the normal administrative user:

```bash
bash scripts/restic-r2-secret.sh
```

The helper asks for:

- Cloudflare account ID;
- R2 Access Key ID;
- R2 Secret Access Key (hidden input);
- a new Restic repository password (hidden input, confirmed twice).

It writes only:

```text
secrets/restic-r2.sops.yaml
```

The output is encrypted with SOPS + age. Plaintext staging uses a temporary mode-0600 file and is removed on exit.

Never paste these credentials into chat, issues, logs, shell command arguments, Terraform variables or unencrypted Git files.

## Install runtime configuration

Run:

```bash
bash scripts/restic-r2-install.sh
```

The script decrypts as the normal user, then installs only the runtime material with sudo under:

```text
/etc/k3s-backup/restic.repository
/etc/k3s-backup/restic.password
/etc/k3s-backup/r2.env
```

The directory is mode `0700`; files are root-owned mode `0600`.

## First real R2 round-trip

Run:

```bash
sudo bash scripts/restic-r2-test.sh
```

The test:

1. selects the newest local K3s backup archive;
2. initializes the R2 Restic repository only when it does not exist;
3. uploads the archive encrypted by Restic;
4. runs `restic check`;
5. restores the latest tagged snapshot to a temporary directory;
6. compares SHA-256 of source and restored archive;
7. removes temporary restored plaintext automatically.

This is intentionally a manual validation step. Scheduled off-host upload and remote retention are added only after the real R2 round-trip succeeds.

## Security notes

- R2 remains private; no public bucket access is required.
- R2 credentials are bucket-scoped and distinct from Terraform credentials.
- Restic encrypts repository data before storage.
- SOPS protects the long-lived credentials at rest in Git; the age private identity remains outside Git.
- Runtime secrets on the host are root-only.
- R2 lifecycle deletion must not be used to prune arbitrary Restic repository objects. Snapshot retention is managed through Restic (`forget`/`prune`) so repository reachability is respected.

## Sources

- Cloudflare R2 — S3 API: https://developers.cloudflare.com/r2/get-started/s3/
- Cloudflare R2 — Authentication: https://developers.cloudflare.com/r2/api/tokens/
- Cloudflare R2 — S3 compatibility: https://developers.cloudflare.com/r2/api/s3/api/
- Restic — Preparing a new repository / S3-compatible storage: https://restic.readthedocs.io/en/latest/030_preparing_a_new_repo.html
- Restic — Password automation: https://restic.readthedocs.io/en/latest/faq.html
