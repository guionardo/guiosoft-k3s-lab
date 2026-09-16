#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${RESTIC_CONFIG_DIR:-/etc/k3s-backup}"
REPO_FILE="$CONFIG_DIR/restic.repository"
PASSWORD_FILE="$CONFIG_DIR/restic.password"
ENV_FILE="$CONFIG_DIR/r2.env"
KEEP_DAILY="${RESTIC_R2_KEEP_DAILY:-14}"
KEEP_WEEKLY="${RESTIC_R2_KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${RESTIC_R2_KEEP_MONTHLY:-12}"
HOST="$(hostname -s)"

[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
for file in "$REPO_FILE" "$PASSWORD_FILE" "$ENV_FILE"; do [[ -s "$file" ]] || { echo "error: missing runtime config: $file" >&2; exit 1; }; done
command -v restic >/dev/null || { echo "error: restic not found" >&2; exit 1; }
for value in "$KEEP_DAILY" "$KEEP_WEEKLY" "$KEEP_MONTHLY"; do [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 )) || { echo "error: retention values must be positive integers" >&2; exit 1; }; done

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
unset RESTIC_REPOSITORY
export RESTIC_REPOSITORY_FILE="$REPO_FILE"
export RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

echo "Restic maintenance: repository preflight..."
restic cat config >/dev/null
restic snapshots --host "$HOST" --json >/dev/null

echo "Restic maintenance: applying control-plane retention/prune..."
restic forget --host "$HOST" --tag k3s-control-plane --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --prune

echo "Restic maintenance: checking repository integrity..."
restic check

echo "Restic maintenance: PASS"
