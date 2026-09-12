#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-secrets/restic-r2.sops.yaml}"
DEST="/etc/k3s-backup"

[[ ${EUID} -ne 0 ]] || {
  echo "error: run this script as the normal user; it invokes sudo only for the final install" >&2
  exit 1
}
[[ -f "$SOURCE" ]] || { echo "error: encrypted config not found: $SOURCE" >&2; exit 1; }
command -v sops >/dev/null || { echo "error: sops not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 0700 "$TMP"

JSON="$TMP/config.json"
sops --decrypt --output-type json "$SOURCE" > "$JSON"
chmod 0600 "$JSON"

ACCOUNT_ID="$(jq -er '.account_id' "$JSON")"
BUCKET="$(jq -er '.bucket' "$JSON")"
ACCESS_KEY_ID="$(jq -er '.access_key_id' "$JSON")"
SECRET_ACCESS_KEY="$(jq -er '.secret_access_key' "$JSON")"
RESTIC_PASSWORD="$(jq -er '.restic_password' "$JSON")"

REPOSITORY="s3:https://${ACCOUNT_ID}.r2.cloudflarestorage.com/${BUCKET}/restic"
printf '%s\n' "$REPOSITORY" > "$TMP/repository"
printf '%s\n' "$RESTIC_PASSWORD" > "$TMP/password"
printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nAWS_DEFAULT_REGION=auto\n' \
  "$ACCESS_KEY_ID" "$SECRET_ACCESS_KEY" > "$TMP/r2.env"
chmod 0600 "$TMP/repository" "$TMP/password" "$TMP/r2.env"

sudo install -d -o root -g root -m 0700 "$DEST"
sudo install -o root -g root -m 0600 "$TMP/repository" "$DEST/restic.repository"
sudo install -o root -g root -m 0600 "$TMP/password" "$DEST/restic.password"
sudo install -o root -g root -m 0600 "$TMP/r2.env" "$DEST/r2.env"

echo "Installed Restic R2 runtime configuration under $DEST (root:root, 0600)."
echo "Plaintext staging was temporary and will be removed now."
