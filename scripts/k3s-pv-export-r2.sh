#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-/var/tmp}"
TAG="${K3S_PV_RESTIC_TAG:-k3s-persistent-volumes}"
RESTORE_DIR="$(mktemp -d /var/tmp/k3s-pv-export.XXXXXX)"
RESTIC_ENV="${RESTIC_R2_ENV:-/etc/k3s-backup/r2.env}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/k3s-backup/restic.password}"
RESTIC_REPOSITORY_FILE="${RESTIC_REPOSITORY_FILE:-/etc/k3s-backup/restic.repository}"
trap 'rm -rf "$RESTORE_DIR"' EXIT

[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
command -v restic >/dev/null || { echo "error: restic not installed" >&2; exit 1; }
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

snapshot_id="$(restic snapshots --tag "$TAG" --json | python3 -c 'import json,sys; x=json.load(sys.stdin); print(max(x, key=lambda s:s["time"])["short_id"] if x else "")')"
[[ -n "$snapshot_id" ]] || { echo "error: no Restic snapshot found with tag $TAG" >&2; exit 1; }

restic restore "$snapshot_id" --target "$RESTORE_DIR"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive="k3s-persistent-volumes-${stamp}-${snapshot_id}.tar.gz"
(
  cd "$RESTORE_DIR"
  # Restic restores the original absolute path below the target. Archive its
  # top-level tree so dr-pv-import can strip exactly one component.
  roots=(*)
  [[ ${#roots[@]} -gt 0 ]] || { echo "error: restored snapshot is empty" >&2; exit 1; }
  tar --numeric-owner -czf "$OUT_DIR/$archive" "${roots[@]}"
)
tar -tzf "$OUT_DIR/$archive" >/dev/null
(
  cd "$OUT_DIR"
  sha256sum "$archive" >"${archive}.sha256"
  sha256sum -c "${archive}.sha256"
)

echo "Portable persistent-volume archive created."
echo "snapshot=$snapshot_id"
echo "archive=$OUT_DIR/$archive"
echo "checksum=$OUT_DIR/${archive}.sha256"
