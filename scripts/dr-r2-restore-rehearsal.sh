#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${RESTIC_CONFIG_DIR:-/etc/k3s-backup}"
REPO_FILE="$CONFIG_DIR/restic.repository"
PASSWORD_FILE="$CONFIG_DIR/restic.password"
ENV_FILE="$CONFIG_DIR/r2.env"
TAG="${RESTIC_R2_TAG:-k3s-control-plane}"
DR_TMP_ROOT="${DR_TMP_ROOT:-/srv/k3s/backups}"

[[ ${EUID} -eq 0 ]] || { echo "error: this rehearsal must run as root" >&2; exit 1; }
command -v restic >/dev/null || { echo "error: restic not found" >&2; exit 1; }
command -v find >/dev/null || { echo "error: find not found" >&2; exit 1; }

for file in "$REPO_FILE" "$PASSWORD_FILE" "$ENV_FILE"; do
  [[ -s "$file" ]] || { echo "error: missing runtime backup config: $file" >&2; exit 1; }
done
[[ -x "$REPO_ROOT/scripts/k3s-backup-verify.sh" || -f "$REPO_ROOT/scripts/k3s-backup-verify.sh" ]] || {
  echo "error: missing verifier: scripts/k3s-backup-verify.sh" >&2
  exit 1
}
[[ -d "$DR_TMP_ROOT" ]] || { echo "error: DR temp root not found: $DR_TMP_ROOT" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
export RESTIC_REPOSITORY_FILE="$REPO_FILE"
export RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

TMP="$(mktemp -d "$DR_TMP_ROOT/.dr-r2-restore.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
chmod 0700 "$TMP"

printf 'R2 disaster-recovery restore rehearsal (isolated)\n'
printf 'Temporary target: %s\n\n' "$TMP"

if ! restic snapshots --tag "$TAG" --latest 1 | grep -q "$TAG"; then
  echo "error: no readable Restic snapshot found with tag $TAG" >&2
  exit 1
fi

echo "Restoring latest $TAG snapshot from R2 into isolated temporary directory..."
restic restore latest --tag "$TAG" --target "$TMP/restore"

ARCHIVE="$(find "$TMP/restore" -type f -name 'k3s-*.tar.gz' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || { echo "error: restored K3s archive not found" >&2; exit 1; }
CHECKSUM="${ARCHIVE}.sha256"
[[ -s "$CHECKSUM" ]] || { echo "error: restored checksum not found: $CHECKSUM" >&2; exit 1; }

mkdir -p "$TMP/verify-work"
chmod 0700 "$TMP/verify-work"

echo
printf 'Validating restored artifact: %s\n' "$(basename "$ARCHIVE")"
K3S_BACKUP_DIR="$TMP/verify-work" bash "$REPO_ROOT/scripts/k3s-backup-verify.sh" "$ARCHIVE"

echo
printf 'R2 DR restore rehearsal OK.\n'
printf 'Verified source: Cloudflare R2 / Restic snapshot tagged %s\n' "$TAG"
echo "Verified: remote restore, archive/checksum presence, SHA-256, server token, SQLite metadata and SQLite integrity."
echo "No live K3s files, local backup archives, or cluster state were modified."
