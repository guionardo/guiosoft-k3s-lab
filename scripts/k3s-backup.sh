#!/usr/bin/env bash
set -euo pipefail

K3S_DATA_DIR="${K3S_DATA_DIR:-/var/lib/rancher/k3s}"
BACKUP_ROOT="${K3S_BACKUP_DIR:-/srv/k3s/backups/k3s}"
DB_DIR="${K3S_DATA_DIR}/server/db"
TOKEN_FILE="${K3S_DATA_DIR}/server/token"

if [[ ${EUID} -ne 0 ]]; then
  echo "error: this backup must run as root" >&2
  exit 1
fi

if [[ ! -d "${DB_DIR}" ]]; then
  echo "error: K3s datastore directory not found: ${DB_DIR}" >&2
  exit 1
fi

if [[ -d "${DB_DIR}/etcd" ]]; then
  echo "error: embedded etcd detected; this script intentionally supports only SQLite" >&2
  echo "use the K3s etcd-snapshot workflow for embedded etcd" >&2
  exit 1
fi

if [[ ! -f "${DB_DIR}/state.db" ]]; then
  echo "error: SQLite state.db not found at ${DB_DIR}/state.db" >&2
  echo "refusing to guess the active datastore type" >&2
  exit 1
fi

if [[ ! -f "${TOKEN_FILE}" ]]; then
  echo "error: K3s server token not found: ${TOKEN_FILE}" >&2
  exit 1
fi

install -d -m 0700 "${BACKUP_ROOT}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HOST="$(hostname -s)"
ARCHIVE="${BACKUP_ROOT}/k3s-${HOST}-${TIMESTAMP}.tar.gz"
CHECKSUM="${ARCHIVE}.sha256"
TMPDIR="$(mktemp -d "${BACKUP_ROOT}/.backup-${TIMESTAMP}.XXXXXX")"
trap 'rm -rf "${TMPDIR}"' EXIT

install -d -m 0700 "${TMPDIR}/server"
cp -a "${DB_DIR}" "${TMPDIR}/server/db"
install -m 0600 "${TOKEN_FILE}" "${TMPDIR}/server/token"

{
  echo "created_at_utc=${TIMESTAMP}"
  echo "hostname=${HOST}"
  echo "datastore=sqlite"
  echo "k3s_data_dir=${K3S_DATA_DIR}"
  if command -v k3s >/dev/null 2>&1; then
    echo "k3s_version=$(k3s --version | head -n1)"
  fi
} > "${TMPDIR}/metadata.txt"

# The archive contains the K3s server token and must be treated as a secret.
tar -C "${TMPDIR}" -czf "${ARCHIVE}" server metadata.txt
chmod 0600 "${ARCHIVE}"
sha256sum "${ARCHIVE}" > "${CHECKSUM}"
chmod 0600 "${CHECKSUM}"

# Verify that the newly written archive is readable before reporting success.
tar -tzf "${ARCHIVE}" >/dev/null
sha256sum -c "${CHECKSUM}" >/dev/null

printf 'K3s SQLite backup created:\n  %s\n  %s\n' "${ARCHIVE}" "${CHECKSUM}"
echo "This is local staging only; an off-host copy and a restore test are still required."
