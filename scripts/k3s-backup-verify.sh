#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${K3S_BACKUP_DIR:-/srv/k3s/backups/k3s}"
ARCHIVE="${1:-}"

if [[ ${EUID} -ne 0 ]]; then
  echo "error: this verification must run as root" >&2
  exit 1
fi

if [[ -z "${ARCHIVE}" ]]; then
  ARCHIVE="$(find "${BACKUP_ROOT}" -maxdepth 1 -type f -name 'k3s-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {$1=""; sub(/^ /, ""); print}')"
fi

if [[ -z "${ARCHIVE}" || ! -f "${ARCHIVE}" ]]; then
  echo "error: backup archive not found" >&2
  echo "usage: $0 [/path/to/k3s-backup.tar.gz]" >&2
  exit 1
fi

CHECKSUM="${ARCHIVE}.sha256"
if [[ ! -f "${CHECKSUM}" ]]; then
  echo "error: checksum file not found: ${CHECKSUM}" >&2
  exit 1
fi

EXPECTED_HASH="$(awk 'NR==1 {print $1}' "${CHECKSUM}")"
ACTUAL_HASH="$(sha256sum "${ARCHIVE}" | awk '{print $1}')"
if [[ -z "${EXPECTED_HASH}" || "${EXPECTED_HASH}" != "${ACTUAL_HASH}" ]]; then
  echo "error: SHA-256 verification failed for ${ARCHIVE}" >&2
  exit 1
fi

TMPDIR="$(mktemp -d "${BACKUP_ROOT}/.restore-test.XXXXXX")"
trap 'rm -rf "${TMPDIR}"' EXIT

tar -C "${TMPDIR}" -xzf "${ARCHIVE}"

DB_FILE="${TMPDIR}/server/db/state.db"
TOKEN_FILE="${TMPDIR}/server/token"
METADATA_FILE="${TMPDIR}/metadata.txt"

if [[ ! -f "${DB_FILE}" ]]; then
  echo "error: restored archive does not contain server/db/state.db" >&2
  exit 1
fi

if [[ -d "${TMPDIR}/server/db/etcd" ]]; then
  echo "error: restored archive unexpectedly contains embedded etcd" >&2
  exit 1
fi

if [[ ! -s "${TOKEN_FILE}" ]]; then
  echo "error: restored archive does not contain a non-empty server token" >&2
  exit 1
fi

if [[ ! -f "${METADATA_FILE}" ]] || ! grep -qx 'datastore=sqlite' "${METADATA_FILE}"; then
  echo "error: backup metadata does not identify the datastore as SQLite" >&2
  exit 1
fi

python3 - "${DB_FILE}" <<'PY'
import sqlite3
import sys

path = sys.argv[1]
conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
try:
    result = conn.execute("PRAGMA integrity_check").fetchone()
finally:
    conn.close()

if not result or result[0] != "ok":
    raise SystemExit(f"SQLite integrity_check failed: {result!r}")
PY

printf 'K3s backup restore rehearsal OK:\n  archive: %s\n' "${ARCHIVE}"
echo "Verified SHA-256, archive extraction, server token presence, SQLite metadata, and SQLite integrity."
if [[ "${K3S_BACKUP_VERIFY_QUIET_CONTEXT:-0}" != "1" ]]; then
  echo "No live K3s files were modified. A full disaster-recovery restore remains a separate destructive test."
fi
