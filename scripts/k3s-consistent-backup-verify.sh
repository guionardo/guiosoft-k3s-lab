#!/usr/bin/env bash
set -euo pipefail

STATE_ROOT="${K3S_CONSISTENT_BACKUP_STATE_ROOT:-/var/lib/guiosoft-k3s-backup/consistent}"
PROD_HOSTNAME="${DR_PRODUCTION_HOSTNAME:-guiosoft-info}"
RESTIC_ENV="${RESTIC_R2_ENV:-/etc/k3s-backup/r2.env}"
RESTIC_REPOSITORY_PATH="${K3S_PV_RESTIC_REPOSITORY_FILE:-/etc/k3s-backup/restic.repository}"
RESTIC_PASSWORD_PATH="${K3S_PV_RESTIC_PASSWORD_FILE:-/etc/k3s-backup/restic.password}"
RUN_DIR="${1:-}"
die(){ echo "error: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "run as root"
command -v restic >/dev/null || die "restic not found"
command -v python3 >/dev/null || die "python3 not found"
for f in "$RESTIC_ENV" "$RESTIC_REPOSITORY_PATH" "$RESTIC_PASSWORD_PATH"; do [[ -s "$f" ]] || die "missing Restic runtime file: $f"; done
if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$(find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2- | while read -r d; do grep -qx 'result=PASS' "$d/metadata" 2>/dev/null && { echo "$d"; break; }; done)"
fi
[[ -n "$RUN_DIR" && -d "$RUN_DIR" && -s "$RUN_DIR/metadata" ]] || die "consistent backup run not found"
declare -A M=(); while IFS='=' read -r k v; do [[ -n "$k" ]] && M["$k"]="$v"; done <"$RUN_DIR/metadata"
[[ "${M[format]:-}" == guiosoft-k3s-consistent-backup-v2 ]] || die "unsupported metadata format: ${M[format]:-missing}"
[[ "${M[result]:-}" == PASS ]] || die "backup set result is not PASS"
[[ "${M[hostname]:-}" == "$PROD_HOSTNAME" ]] || die "unexpected source hostname: ${M[hostname]:-missing}"
for k in backup_set_id quiesced_at control_plane_archive control_plane_restic_snapshot_id control_plane_restic_snapshot_time pv_restic_snapshot_id pv_restic_snapshot_time completed_backup_window_at consistency_window_seconds writers_restored_at; do [[ -n "${M[$k]:-}" ]] || die "metadata field missing: $k"; done
[[ "${M[consistency_window_seconds]}" =~ ^[0-9]+$ ]] || die "invalid consistency window"
set -a
# shellcheck disable=SC1090
source "$RESTIC_ENV"
set +a
unset RESTIC_REPOSITORY RESTIC_REPOSITORY_FILE
export RESTIC_REPOSITORY_FILE="$RESTIC_REPOSITORY_PATH" RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_PATH"
restic cat config >/dev/null || die "Restic repository unavailable"
CP="${M[control_plane_restic_snapshot_id]}"; PV="${M[pv_restic_snapshot_id]}"; CP_BASE="${M[control_plane_archive]}"
restic snapshots "$CP" --json | python3 -c 'import json,sys; x=json.load(sys.stdin); sys.exit(0 if x else 1)' || die "control-plane snapshot not found: $CP"
CP_LIST="$(mktemp)"; PV_LIST="$(mktemp)"; trap 'rm -f "$CP_LIST" "$PV_LIST"' EXIT
restic ls "$CP" >"$CP_LIST"
awk '{print $NF}' "$CP_LIST" | awk -F/ -v expected="$CP_BASE" '$NF == expected {found=1} END {exit !found}' || die "control-plane archive absent from snapshot $CP"
restic snapshots "$PV" --json | python3 -c 'import json,sys; x=json.load(sys.stdin); sys.exit(0 if x else 1)' || die "PV snapshot not found: $PV"
# `restic ls` may list the root itself as /mnt/store1/k3s/local-path before any
# child entry. Accept either the exact root or descendants, and avoid grep -q so
# pipefail cannot turn grep's early exit/SIGPIPE into a false verification error.
restic ls "$PV" >"$PV_LIST"
awk '{print $NF}' "$PV_LIST" | grep -E '^/mnt/store1/k3s/local-path(/|$)' >/dev/null || die "PV snapshot does not contain expected local-path root"
python3 - "${M[quiesced_at]}" "${M[control_plane_restic_snapshot_time]}" "${M[pv_restic_snapshot_time]}" "${M[completed_backup_window_at]}" <<'PY'
import datetime,sys
def dt(v): return datetime.datetime.fromisoformat(v.replace('Z','+00:00'))
q,cp,pv,end=map(dt,sys.argv[1:])
if not (q <= cp <= end): raise SystemExit('control-plane snapshot time outside consistency window')
if not (q <= pv <= end): raise SystemExit('PV snapshot time outside consistency window')
PY
echo "Consistent recovery-set verification: PASS"
echo "backup_set_id=${M[backup_set_id]}"
echo "control_plane_snapshot=${CP}"
echo "pv_snapshot=${PV}"
echo "consistency_window_seconds=${M[consistency_window_seconds]}"
echo "writers_restored_at=${M[writers_restored_at]}"
