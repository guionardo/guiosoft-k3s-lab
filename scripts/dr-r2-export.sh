#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${RESTIC_CONFIG_DIR:-/etc/k3s-backup}"
REPO_FILE="$CONFIG_DIR/restic.repository"
PASSWORD_FILE="$CONFIG_DIR/restic.password"
ENV_FILE="$CONFIG_DIR/r2.env"
TAG="${RESTIC_R2_TAG:-k3s-control-plane}"
DEST="${1:-}"

[[ ${EUID} -eq 0 ]] || { echo "error: this export must run as root" >&2; exit 1; }
[[ -n "$DEST" ]] || { echo "usage: $0 /path/to/export-directory" >&2; exit 2; }

case "$DEST" in
  /var/lib/rancher/k3s|/var/lib/rancher/k3s/*)
    echo "error: refusing to export directly into the live K3s data directory" >&2
    exit 1
    ;;
esac

for file in "$REPO_FILE" "$PASSWORD_FILE" "$ENV_FILE"; do
  [[ -s "$file" ]] || { echo "error: missing runtime backup config: $file" >&2; exit 1; }
done
command -v restic >/dev/null || { echo "error: restic not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
export RESTIC_REPOSITORY_FILE="$REPO_FILE"
export RESTIC_PASSWORD_FILE="$PASSWORD_FILE"

install -d -m 0700 "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 0700 "$TMP"

# Do not rely on `restic snapshots --latest 1` or `restic restore latest` here.
# Restic 0.18 can still present multiple tagged snapshots in ways that make a
# human-readable latest selection ambiguous. Select the maximum timestamp from
# JSON and restore that exact immutable snapshot ID.
SNAPSHOT_ID="$(restic snapshots --tag "$TAG" --json | python3 -c '
import json,sys,datetime
items=json.load(sys.stdin)
if not items:
    raise SystemExit(1)
def ts(o):
    return datetime.datetime.fromisoformat(o["time"].replace("Z", "+00:00"))
print(max(items, key=ts)["id"])
')" || { echo "error: no readable Restic snapshot found with tag $TAG" >&2; exit 1; }
[[ -n "$SNAPSHOT_ID" ]] || { echo "error: empty Restic snapshot ID for tag $TAG" >&2; exit 1; }

echo "Selected Restic snapshot: $SNAPSHOT_ID (tag=$TAG)"
restic restore "$SNAPSHOT_ID" --target "$TMP/restore" >/dev/null

ARCHIVE="$(find "$TMP/restore" -type f -name 'k3s-*.tar.gz' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || { echo "error: restored K3s archive not found" >&2; exit 1; }
CHECKSUM="${ARCHIVE}.sha256"
[[ -s "$CHECKSUM" ]] || { echo "error: restored checksum not found: $CHECKSUM" >&2; exit 1; }

VERIFY_DIR="$TMP/verify"
mkdir -p "$VERIFY_DIR"
K3S_BACKUP_DIR="$VERIFY_DIR" bash "$REPO_ROOT/scripts/k3s-backup-verify.sh" "$ARCHIVE" >/dev/null

install -m 0600 "$ARCHIVE" "$DEST/$(basename "$ARCHIVE")"
install -m 0600 "$CHECKSUM" "$DEST/$(basename "$CHECKSUM")"

echo "Verified K3s DR artifact exported from Cloudflare R2:"
echo "  snapshot=$SNAPSHOT_ID"
echo "  $DEST/$(basename "$ARCHIVE")"
echo "  $DEST/$(basename "$CHECKSUM")"
echo "The archive contains the K3s server token and must be handled as a secret."
