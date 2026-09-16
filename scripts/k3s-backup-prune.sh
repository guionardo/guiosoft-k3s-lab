#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${K3S_BACKUP_DIR:-/srv/k3s/backups/k3s}"
KEEP="${K3S_BACKUP_KEEP:-14}"

if [[ ${EUID} -ne 0 ]]; then
  echo "error: backup retention must run as root" >&2
  exit 1
fi

if ! [[ "${KEEP}" =~ ^[0-9]+$ ]] || (( KEEP < 2 )); then
  echo "error: K3S_BACKUP_KEEP must be an integer >= 2" >&2
  exit 1
fi

if [[ ! -d "${BACKUP_ROOT}" ]]; then
  echo "error: backup directory not found: ${BACKUP_ROOT}" >&2
  exit 1
fi

mapfile -t ARCHIVES < <(
  find "${BACKUP_ROOT}" -maxdepth 1 -type f -name 'k3s-*.tar.gz' -printf '%T@ %p\n' \
    | sort -nr \
    | awk '{sub(/^[^ ]+ /, ""); print}'
)

TOTAL=${#ARCHIVES[@]}
if (( TOTAL <= KEEP )); then
  echo "K3s backup retention: ${TOTAL} archive(s), keeping ${KEEP}; nothing to prune."
  exit 0
fi

for (( i=KEEP; i<TOTAL; i++ )); do
  ARCHIVE="${ARCHIVES[$i]}"
  CHECKSUM="${ARCHIVE}.sha256"

  # Refuse to delete an archive that does not have its checksum partner. This avoids
  # hiding an incomplete backup set and leaves it for manual inspection.
  if [[ ! -f "${CHECKSUM}" ]]; then
    echo "warning: refusing to prune archive without checksum: ${ARCHIVE}" >&2
    continue
  fi

  echo "Pruning old K3s backup: ${ARCHIVE}"
  rm -- "${ARCHIVE}" "${CHECKSUM}"
done
