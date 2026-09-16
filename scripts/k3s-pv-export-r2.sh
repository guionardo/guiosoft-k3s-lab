#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-/var/tmp}"
TAG="${K3S_PV_RESTIC_TAG:-k3s-persistent-volumes}"
K3S_PV_ROOT="${K3S_PV_ROOT:-/mnt/store1/k3s/local-path}"
RESTORE_DIR="$(mktemp -d /var/tmp/k3s-pv-export.XXXXXX)"
RESTIC_ENV="${RESTIC_R2_ENV:-/etc/k3s-backup/r2.env}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/k3s-backup/restic.password}"
RESTIC_REPOSITORY_FILE="${RESTIC_REPOSITORY_FILE:-/etc/k3s-backup/restic.repository}"
trap 'rm -rf "$RESTORE_DIR"' EXIT

[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
command -v restic >/dev/null || { echo "error: restic not installed" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not installed" >&2; exit 1; }
for f in "$RESTIC_ENV" "$RESTIC_PASSWORD_FILE" "$RESTIC_REPOSITORY_FILE"; do
  [[ -s "$f" ]] || { echo "error: missing Restic runtime file: $f" >&2; exit 1; }
done
install -d -m 0755 "$OUT_DIR"

set -a
# shellcheck disable=SC1090
source "$RESTIC_ENV"
set +a
export RESTIC_PASSWORD_FILE
export RESTIC_REPOSITORY="$(cat "$RESTIC_REPOSITORY_FILE")"

snapshot_id="$(restic snapshots --tag "$TAG" --json | python3 -c 'import json,sys,datetime; x=json.load(sys.stdin); print(max(x, key=lambda s:datetime.datetime.fromisoformat(s["time"].replace("Z","+00:00")))["id"] if x else "")')"
[[ -n "$snapshot_id" ]] || { echo "error: no Restic snapshot found with tag $TAG" >&2; exit 1; }

restic restore "$snapshot_id" --target "$RESTORE_DIR"
restored_pv_root="$RESTORE_DIR$K3S_PV_ROOT"
[[ -d "$restored_pv_root" ]] || {
  echo "error: expected PV root not present in restored snapshot: $K3S_PV_ROOT" >&2
  exit 1
}
[[ -n "$(find "$restored_pv_root" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]] || {
  echo "error: restored PV root is empty: $K3S_PV_ROOT" >&2
  exit 1
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
short_id="${snapshot_id:0:8}"
archive="k3s-persistent-volumes-${stamp}-${short_id}.tar.gz"

# Portable format v1: archive only the CONTENTS of the production local-path
# root. Consumers extract directly into their chosen DR storage root. This
# avoids embedding /mnt/store1/... or relying on --strip-components guesses.
tar --numeric-owner -C "$restored_pv_root" -czf "$OUT_DIR/$archive" .
tar -tzf "$OUT_DIR/$archive" >/dev/null
(
  cd "$OUT_DIR"
  sha256sum "$archive" >"${archive}.sha256"
  sha256sum -c "${archive}.sha256"
)

cat >"$OUT_DIR/${archive}.metadata" <<EOF
format=k3s-pv-archive-v1
snapshot_id=$snapshot_id
source_root=$K3S_PV_ROOT
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0600 "$OUT_DIR/$archive" "$OUT_DIR/${archive}.sha256" "$OUT_DIR/${archive}.metadata"

echo "Portable persistent-volume archive created."
echo "format=k3s-pv-archive-v1"
echo "snapshot=$snapshot_id"
echo "archive=$OUT_DIR/$archive"
echo "checksum=$OUT_DIR/${archive}.sha256"
echo "metadata=$OUT_DIR/${archive}.metadata"
