#!/usr/bin/env bash
set -euo pipefail

OUTPUT="${1:-secrets/restic-r2.sops.yaml}"
BUCKET="${R2_BUCKET:-guiosoft-k3s-backups}"

command -v sops >/dev/null || { echo "error: sops not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq not found" >&2; exit 1; }

mkdir -p "$(dirname "$OUTPUT")"

read -r -p "Cloudflare account ID: " ACCOUNT_ID
read -r -p "R2 Access Key ID: " ACCESS_KEY_ID
read -r -s -p "R2 Secret Access Key: " SECRET_ACCESS_KEY; echo
read -r -s -p "New Restic repository password: " RESTIC_PASSWORD; echo
read -r -s -p "Confirm Restic repository password: " RESTIC_PASSWORD_CONFIRM; echo

[[ -n "$ACCOUNT_ID" && -n "$ACCESS_KEY_ID" && -n "$SECRET_ACCESS_KEY" && -n "$RESTIC_PASSWORD" ]] || {
  echo "error: all values are required" >&2
  exit 1
}
[[ "$RESTIC_PASSWORD" == "$RESTIC_PASSWORD_CONFIRM" ]] || {
  echo "error: Restic passwords do not match" >&2
  exit 1
}

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
chmod 0600 "$TMP"

jq -n \
  --arg account_id "$ACCOUNT_ID" \
  --arg bucket "$BUCKET" \
  --arg access_key_id "$ACCESS_KEY_ID" \
  --arg secret_access_key "$SECRET_ACCESS_KEY" \
  --arg restic_password "$RESTIC_PASSWORD" \
  '{account_id:$account_id,bucket:$bucket,access_key_id:$access_key_id,secret_access_key:$secret_access_key,restic_password:$restic_password}' \
  > "$TMP"

sops --encrypt \
  --config .sops.yaml \
  --filename-override "$OUTPUT" \
  --input-type json \
  --output-type yaml \
  "$TMP" > "$OUTPUT"
chmod 0600 "$OUTPUT"

echo "Encrypted R2/Restic configuration written to $OUTPUT"
echo "Review with: sops --decrypt $OUTPUT"
echo "Only the SOPS-encrypted file may be committed."
