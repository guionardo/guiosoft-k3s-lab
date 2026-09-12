#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${RESTIC_CONFIG_DIR:-/etc/k3s-backup}"
BACKUP_DIR="${K3S_BACKUP_DIR:-/srv/k3s/backups/k3s}"
REPO_FILE="$CONFIG_DIR/restic.repository"
PASSWORD_FILE="$CONFIG_DIR/restic.password"
ENV_FILE="$CONFIG_DIR/r2.env"
KEEP_DAILY="${RESTIC_R2_KEEP_DAILY:-14}"
KEEP_WEEKLY="${RESTIC_R2_KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${RESTIC_R2_KEEP_MONTHLY:-12}"
HOST="$(hostname -s)"
TAG="k3s-control-plane"

[[ ${EUID} -eq 0 ]] || { echo "error: this script must run as root" >&2; exit 1; }
for file in "$REPO_FILE" "$PASSWORD_FILE" "$ENV_FILE"; do
  [[ -s "$file" ]] || { echo "error: missing runtime config: $file" >&2; exit 1; }
done
command -v restic >/dev/null || { echo "error: restic not found" >&2; exit 1; }

for value in "$KEEP_DAILY" "$KEEP_WEEKLY" "$KEEP_MONTHLY"; do
  [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 )) || {
    echo "error: Restic retention values must be positive integers" >&2
    exit 1
  }
done

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
export RESTIC_REPOSITORY_FILE="$REPO_FILE"
export RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

ARCHIVE="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'k3s-*.tar.gz' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
[[ -n "$ARCHIVE" ]] || { echo "error: no local K3s backup archive found" >&2; exit 1; }
CHECKSUM="${ARCHIVE}.sha256"
[[ -s "$CHECKSUM" ]] || { echo "error: checksum missing for $ARCHIVE" >&2; exit 1; }

(
  cd "$BACKUP_DIR"
  sha256sum -c "$(basename "$CHECKSUM")"
)

if ! restic cat config >/dev/null 2>&1; then
  echo "Initializing encrypted Restic repository in Cloudflare R2..."
  restic init
fi

echo "Uploading latest verified K3s backup to Cloudflare R2..."
restic backup "$ARCHIVE" "$CHECKSUM" --tag "$TAG" --host "$HOST"

echo "Applying Restic snapshot retention..."
restic forget \
  --host "$HOST" \
  --tag "$TAG" \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  --prune

restic snapshots --host "$HOST" --tag "$TAG" --latest 1

echo "Cloudflare R2 off-host backup OK."
echo "Uploaded: $(basename "$ARCHIVE") and $(basename "$CHECKSUM")"
