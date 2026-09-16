#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K3S_DATA_DIR="${K3S_DATA_DIR:-/var/lib/rancher/k3s}"
MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"
PROD_HOSTNAME="${DR_PRODUCTION_HOSTNAME:-guiosoft-info}"
PROD_IP="${DR_PRODUCTION_IP:-192.168.88.9}"
CONFIRM_EXPECTED="restore-isolated-k3s"
ARCHIVE="${1:-}"
HOST="$(hostname -s)"

[[ ${EUID} -eq 0 ]] || { echo "error: this restore must run as root" >&2; exit 1; }
[[ -n "$ARCHIVE" ]] || { echo "usage: DR_RESTORE_CONFIRM=$CONFIRM_EXPECTED $0 /path/to/k3s-backup.tar.gz" >&2; exit 2; }
[[ -f "$ARCHIVE" ]] || { echo "error: archive not found: $ARCHIVE" >&2; exit 1; }
[[ -s "$MARKER_FILE" ]] || { echo "error: DR target marker missing: $MARKER_FILE" >&2; exit 1; }
grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" || { echo "error: invalid DR target marker" >&2; exit 1; }

if [[ "$HOST" == "$PROD_HOSTNAME" ]]; then
  echo "error: refusing destructive restore on production hostname '$HOST'" >&2
  exit 1
fi
if ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PROD_IP"; then
  echo "error: refusing destructive restore on production IP $PROD_IP" >&2
  exit 1
fi
[[ "${DR_RESTORE_CONFIRM:-}" == "$CONFIRM_EXPECTED" ]] || {
  echo "error: explicit confirmation required" >&2
  echo "run with DR_RESTORE_CONFIRM=$CONFIRM_EXPECTED" >&2
  exit 1
}

command -v systemctl >/dev/null || { echo "error: systemctl not found" >&2; exit 1; }
command -v k3s >/dev/null || { echo "error: k3s not installed on DR target" >&2; exit 1; }

CHECKSUM="${ARCHIVE}.sha256"
[[ -s "$CHECKSUM" ]] || { echo "error: checksum file not found: $CHECKSUM" >&2; exit 1; }

VERIFY_DIR="$(mktemp -d)"
RESTORE_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR" "$RESTORE_DIR"' EXIT
chmod 0700 "$VERIFY_DIR" "$RESTORE_DIR"

K3S_BACKUP_DIR="$VERIFY_DIR" K3S_BACKUP_VERIFY_QUIET_CONTEXT=1 \
  bash "$REPO_ROOT/scripts/k3s-backup-verify.sh" "$ARCHIVE"

tar -C "$RESTORE_DIR" -xzf "$ARCHIVE"
[[ -d "$RESTORE_DIR/server/db" ]] || { echo "error: server/db missing after extraction" >&2; exit 1; }
[[ -s "$RESTORE_DIR/server/token" ]] || { echo "error: server/token missing after extraction" >&2; exit 1; }

systemctl stop k3s
if systemctl is-active --quiet k3s; then
  echo "error: k3s is still active after stop request" >&2
  exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SAFETY_DIR="$K3S_DATA_DIR/dr-pre-restore-$STAMP"
BOOTSTRAP_DIR="$SAFETY_DIR/pre-restore-bootstrap"
install -d -m 0700 "$SAFETY_DIR" "$BOOTSTRAP_DIR"

if [[ -d "$K3S_DATA_DIR/server/db" ]]; then
  cp -a "$K3S_DATA_DIR/server/db" "$SAFETY_DIR/db"
fi
if [[ -f "$K3S_DATA_DIR/server/token" ]]; then
  install -m 0600 "$K3S_DATA_DIR/server/token" "$SAFETY_DIR/token"
fi

# A clean DR K3s installation has bootstrap TLS/credential files generated from
# its own datastore. They may be newer than the restored datastore, in which
# case K3s deliberately refuses startup. Preserve them for rollback and remove
# them from the live server directory so K3s can reconstruct bootstrap state
# from the restored datastore.
for bootstrap_item in tls cred; do
  if [[ -e "$K3S_DATA_DIR/server/$bootstrap_item" ]]; then
    mv "$K3S_DATA_DIR/server/$bootstrap_item" "$BOOTSTRAP_DIR/$bootstrap_item"
  fi
done

rm -rf "$K3S_DATA_DIR/server/db"
install -d -m 0700 "$K3S_DATA_DIR/server"
cp -a "$RESTORE_DIR/server/db" "$K3S_DATA_DIR/server/db"
install -m 0600 "$RESTORE_DIR/server/token" "$K3S_DATA_DIR/server/token"

if ! systemctl start k3s; then
  systemctl stop k3s || true
  echo "error: k3s failed to start after datastore restore" >&2
  journalctl -u k3s -n 80 --no-pager >&2 || true
  echo "Pre-restore DR-target state is preserved at: $SAFETY_DIR" >&2
  exit 1
fi

for _ in $(seq 1 60); do
  if k3s kubectl get --raw=/readyz >/dev/null 2>&1; then
    echo "K3s API is ready after DR restore."
    k3s kubectl get nodes -o wide
    echo "Safety copy of the pre-restore DR-target state: $SAFETY_DIR"
    echo "Guarded isolated K3s restore completed."
    exit 0
  fi
  sleep 2
done

systemctl stop k3s || true
echo "error: K3s did not become ready after restore; service was stopped for inspection" >&2
journalctl -u k3s -n 80 --no-pager >&2 || true
echo "Pre-restore DR-target state is preserved at: $SAFETY_DIR" >&2
exit 1
