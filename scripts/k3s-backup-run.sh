#!/usr/bin/env bash
set -euo pipefail

LOCK_FILE="${K3S_BACKUP_LOCK_FILE:-/run/lock/guiosoft-k3s-backup.lock}"

[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
command -v flock >/dev/null || { echo "error: flock not found" >&2; exit 1; }

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "error: another K3s backup or repository maintenance job is already running" >&2; exit 75; }

/usr/local/sbin/k3s-backup
/usr/local/sbin/k3s-backup-prune
if [[ "${RESTIC_R2_ENABLED:-1}" == 1 ]]; then
  /usr/local/sbin/restic-r2-sync
fi
