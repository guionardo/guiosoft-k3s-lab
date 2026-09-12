# Cloudflare R2 backup bucket

This Terraform stack manages only the R2 bucket used by Restic for off-host K3s backups.

It is intentionally separate from `terraform/cloudflare/` so the existing DNS/Tunnel stack can keep its current zero-drift state and its narrower API token permissions.

## Authentication

Use a dedicated Cloudflare API token through:

```bash
export CLOUDFLARE_API_TOKEN='...'
```

The token used by this stack needs the account-level permission accepted by the Cloudflare provider for `cloudflare_r2_bucket`:

```text
Workers R2 Storage: Write
```

Do not commit this token.

This Terraform token is **not** the same credential Restic will use to access the S3-compatible R2 API.

## Local variables

Create an ignored local file:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Set the Cloudflare account ID and, optionally, change the bucket name. The location hint is deliberately left unset by default so Cloudflare may choose automatically.

## Safe workflow

```bash
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan
terraform apply
```

The bucket is protected with `prevent_destroy = true`.

## Restic credentials

After the bucket exists, create a separate R2 S3 API credential in the Cloudflare dashboard with **Object Read & Write** permission restricted to this bucket only.

Cloudflare provides:

- Access Key ID;
- Secret Access Key;
- S3 endpoint in the form `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.

Those credentials and the Restic repository password are secrets. They will be stored encrypted with SOPS + age before the automated off-host service is enabled.

The planned Restic repository URL is:

```text
s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/<BUCKET_NAME>
```

Do not configure an independent R2 lifecycle rule that deletes arbitrary Restic objects. Restic must own repository retention because repository pack files can be shared by multiple snapshots.

## Sources

- Cloudflare R2 S3 API: https://developers.cloudflare.com/r2/get-started/s3/
- Cloudflare R2 authentication: https://developers.cloudflare.com/r2/api/tokens/
- Cloudflare Terraform `cloudflare_r2_bucket`: https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/r2_bucket
- Restic S3-compatible storage: https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html
