#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${GUIOSOFT_K3S_REPO_ROOT:-/opt/guiosoft-k3s-lab}"
LOCK_FILE="${K3S_BACKUP_LOCK_FILE:-/run/lock/guiosoft-k3s-backup.lock}"
LOG_TAG="k3s-consistent-backup"

[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
command -v flock >/dev/null || { echo "error: flock not found" >&2; exit 1; }
for script in k3s-consistent-backup.sh k3s-consistent-backup-verify.sh k3s-restic-maintenance.sh; do
  [[ -x "$REPO_ROOT/scripts/$script" ]] || { echo "error: dependency not executable: $REPO_ROOT/scripts/$script" >&2; exit 1; }
done

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "error: another K3s backup or repository maintenance job is already running" >&2; exit 75; }

echo "$LOG_TAG: starting $(date -u +%Y-%m-%dT%H:%M:%SZ)"
env K3S_CONSISTENT_BACKUP_CONFIRM=backup-consistent-production-state \
  bash "$REPO_ROOT/scripts/k3s-consistent-backup.sh"
echo "$LOG_TAG: recovery set captured; starting independent verification"
bash "$REPO_ROOT/scripts/k3s-consistent-backup-verify.sh"
echo "$LOG_TAG: recovery set verified; starting repository maintenance"
bash "$REPO_ROOT/scripts/k3s-restic-maintenance.sh"
echo "$LOG_TAG: completed $(date -u +%Y-%m-%dT%H:%M:%SZ)"
