#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${K3S_BACKUP_DIR:-/srv/k3s/backups/k3s}"

if [[ ${EUID} -ne 0 ]]; then
  echo "error: this test must run as root because K3s backup archives are mode 0600" >&2
  exit 1
fi

if ! command -v restic >/dev/null 2>&1; then
  echo "error: restic is not installed; run 'make tools' first" >&2
  exit 1
fi

ARCHIVE="$(find "${BACKUP_ROOT}" -maxdepth 1 -type f -name 'k3s-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
if [[ -z "${ARCHIVE}" || ! -f "${ARCHIVE}" ]]; then
  echo "error: no K3s backup archive found under ${BACKUP_ROOT}" >&2
  echo "run 'make backup-create' first" >&2
  exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

REPO="${TMPDIR}/repo"
PASSWORD_FILE="${TMPDIR}/password"
RESTORE_DIR="${TMPDIR}/restore"
SOURCE_DIR="${TMPDIR}/source"

install -d -m 0700 "${REPO}" "${RESTORE_DIR}" "${SOURCE_DIR}"
printf '%s\n' "$(head -c 48 /dev/urandom | base64 | tr -d '\n')" > "${PASSWORD_FILE}"
chmod 0600 "${PASSWORD_FILE}"

cp -a "${ARCHIVE}" "${SOURCE_DIR}/"
if [[ -f "${ARCHIVE}.sha256" ]]; then
  cp -a "${ARCHIVE}.sha256" "${SOURCE_DIR}/"
fi

export RESTIC_REPOSITORY="${REPO}"
export RESTIC_PASSWORD_FILE="${PASSWORD_FILE}"

restic init >/dev/null
restic backup "${SOURCE_DIR}" --tag k3s-offsite-smoke-test >/dev/null
restic check >/dev/null
restic restore latest --target "${RESTORE_DIR}" >/dev/null

RESTORED_ARCHIVE="${RESTORE_DIR}${SOURCE_DIR}/$(basename "${ARCHIVE}")"
if [[ ! -f "${RESTORED_ARCHIVE}" ]]; then
  echo "error: restored archive not found: ${RESTORED_ARCHIVE}" >&2
  exit 1
fi

cmp -s "${ARCHIVE}" "${RESTORED_ARCHIVE}" || {
  echo "error: restored archive differs from source" >&2
  exit 1
}

printf 'Restic local round-trip OK:\n  source: %s\n' "${ARCHIVE}"
echo "Verified repository init, encrypted backup, repository check, restore, and byte-for-byte archive equality."
echo "The temporary restic repository was removed automatically; no off-host destination was configured."
