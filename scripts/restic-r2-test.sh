#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${RESTIC_CONFIG_DIR:-/etc/k3s-backup}"
BACKUP_DIR="${K3S_BACKUP_DIR:-/srv/k3s/backups/k3s}"
REPO_FILE="$CONFIG_DIR/restic.repository"
PASSWORD_FILE="$CONFIG_DIR/restic.password"
ENV_FILE="$CONFIG_DIR/r2.env"

[[ ${EUID} -eq 0 ]] || { echo "error: this test must run as root" >&2; exit 1; }
for file in "$REPO_FILE" "$PASSWORD_FILE" "$ENV_FILE"; do
  [[ -s "$file" ]] || { echo "error: missing runtime config: $file" >&2; exit 1; }
done
command -v restic >/dev/null || { echo "error: restic not found" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
export RESTIC_REPOSITORY_FILE="$REPO_FILE"
export RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

ARCHIVE="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'k3s-*.tar.gz' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
[[ -n "$ARCHIVE" ]] || { echo "error: no local K3s backup archive found" >&2; exit 1; }

if ! restic cat config >/dev/null 2>&1; then
  echo "Initializing encrypted Restic repository in Cloudflare R2..."
  restic init
fi

SOURCE_SHA="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
restic backup "$ARCHIVE" --tag k3s-control-plane --host "$(hostname -s)"
restic check

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 0700 "$TMP"
restic restore latest --tag k3s-control-plane --target "$TMP"
RESTORED="$TMP${ARCHIVE}"
[[ -f "$RESTORED" ]] || { echo "error: restored archive not found: $RESTORED" >&2; exit 1; }
RESTORED_SHA="$(sha256sum "$RESTORED" | awk '{print $1}')"
[[ "$SOURCE_SHA" == "$RESTORED_SHA" ]] || { echo "error: restored archive checksum differs" >&2; exit 1; }

echo "Cloudflare R2 Restic round-trip OK."
echo "Verified encrypted upload, repository check, restore, and byte-for-byte SHA-256 equality."
echo "Source: $ARCHIVE"
