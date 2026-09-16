#!/usr/bin/env bash
set -euo pipefail

BACKUP_FILE="${AGE_BACKUP_FILE:-${1:-}}"
TARGET="${AGE_RESTORE_TARGET:-${HOME}/.config/sops/age/keys.txt}"
PASSPHRASE_FILE="${AGE_BACKUP_PASSPHRASE_FILE:-}"

need() {
  command -v "$1" >/dev/null || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in openssl sha256sum mktemp install dirname grep; do
  need "$cmd"
done

[[ -n "$BACKUP_FILE" ]] || {
  echo "usage: AGE_BACKUP_FILE=/path/to/age-identity-...enc $0" >&2
  echo "   or: $0 /path/to/age-identity-...enc" >&2
  exit 1
}

[[ -f "$BACKUP_FILE" ]] || {
  echo "error: encrypted backup not found: $BACKUP_FILE" >&2
  exit 1
}

sum_file="${BACKUP_FILE%.enc}.sha256"
[[ -f "$sum_file" ]] || {
  echo "error: checksum file not found: $sum_file" >&2
  exit 1
}

(
  cd "$(dirname "$BACKUP_FILE")"
  sha256sum -c "$(basename "$sum_file")"
)

umask 077
tmp="$(mktemp)"
cleanup() {
  rm -f "$tmp"
}
trap cleanup EXIT

if [[ -n "$PASSPHRASE_FILE" ]]; then
  [[ -f "$PASSPHRASE_FILE" ]] || {
    echo "error: AGE_BACKUP_PASSPHRASE_FILE not found" >&2
    exit 1
  }
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
    -in "$BACKUP_FILE" -out "$tmp" \
    -pass "file:$PASSPHRASE_FILE"
else
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
    -in "$BACKUP_FILE" -out "$tmp"
fi

if ! grep -q '^AGE-SECRET-KEY-' "$tmp"; then
  echo "error: decrypted file does not look like an age identity" >&2
  exit 1
fi

if [[ -e "$TARGET" ]]; then
  echo "error: restore target already exists: $TARGET" >&2
  echo "refusing to overwrite an existing age identity" >&2
  exit 1
fi

install -d -m 0700 "$(dirname "$TARGET")"
install -m 0600 "$tmp" "$TARGET"

echo "age identity restored to: $TARGET"
echo "Validate it before relying on it:"
echo "  age-keygen -y '$TARGET'"
echo "  sops -d <one-known-secret.sops.yaml> >/dev/null"
