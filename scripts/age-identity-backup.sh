#!/usr/bin/env bash
set -euo pipefail

SOURCE="${AGE_IDENTITY_FILE:-${HOME}/.config/sops/age/keys.txt}"
DEST="${AGE_BACKUP_DEST:-}"
PASSPHRASE_FILE="${AGE_BACKUP_PASSPHRASE_FILE:-}"

need() {
  command -v "$1" >/dev/null || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in openssl sha256sum mktemp install date hostname readlink awk; do
  need "$cmd"
done

[[ -f "$SOURCE" ]] || {
  echo "error: age identity not found: $SOURCE" >&2
  exit 1
}

[[ -n "$DEST" ]] || {
  echo "error: AGE_BACKUP_DEST must point to an explicitly mounted off-host directory" >&2
  exit 1
}

[[ -d "$DEST" ]] || {
  echo "error: AGE_BACKUP_DEST is not a directory: $DEST" >&2
  exit 1
}

source_real="$(readlink -f "$SOURCE")"
dest_real="$(readlink -f "$DEST")"

case "$dest_real" in
  /|/home|/home/*|/root|/root/*|/tmp|/tmp/*|/var|/var/*)
    echo "error: refusing destination that looks local to the host: $dest_real" >&2
    echo "mount an off-host filesystem (USB/NAS/etc.) and point AGE_BACKUP_DEST to it" >&2
    exit 1
    ;;
esac

if [[ "$source_real" == "$dest_real"/* ]]; then
  echo "error: backup destination contains the source identity path" >&2
  exit 1
fi

umask 077
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
host="$(hostname -s)"
base="age-identity-${host}-${stamp}"
out="$DEST/${base}.enc"
sum="$DEST/${base}.sha256"

plain_tmp="$(mktemp)"
verify_tmp="$(mktemp)"
cleanup() {
  rm -f "$plain_tmp" "$verify_tmp"
}
trap cleanup EXIT

install -m 0600 "$SOURCE" "$plain_tmp"
source_sha="$(sha256sum "$plain_tmp" | awk '{print $1}')"

if [[ -n "$PASSPHRASE_FILE" ]]; then
  [[ -f "$PASSPHRASE_FILE" ]] || {
    echo "error: AGE_BACKUP_PASSPHRASE_FILE not found" >&2
    exit 1
  }
  openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 \
    -in "$plain_tmp" -out "$out" \
    -pass "file:$PASSPHRASE_FILE"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
    -in "$out" -out "$verify_tmp" \
    -pass "file:$PASSPHRASE_FILE"
else
  echo "Enter a dedicated DR passphrase. It must be stored separately from this server and repository."
  openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 \
    -in "$plain_tmp" -out "$out"
  echo "Re-enter the same DR passphrase to verify the encrypted backup."
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
    -in "$out" -out "$verify_tmp"
fi

verify_sha="$(sha256sum "$verify_tmp" | awk '{print $1}')"
[[ "$source_sha" == "$verify_sha" ]] || {
  rm -f "$out"
  echo "error: verification checksum does not match source identity" >&2
  exit 1
}

printf '%s  %s\n' "$(sha256sum "$out" | awk '{print $1}')" "$(basename "$out")" > "$sum"
chmod 0600 "$out" "$sum"

sync "$out" "$sum" 2>/dev/null || true

echo "Encrypted age identity backup created and verified:"
echo "  $out"
echo "  $sum"
echo "Source plaintext was never written to the destination."
echo "Keep the DR passphrase independently from the host, Git repository, SOPS secrets and Restic credentials."
