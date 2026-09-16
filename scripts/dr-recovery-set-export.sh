#!/usr/bin/env bash
set -euo pipefail

STATE_ROOT="${K3S_CONSISTENT_BACKUP_STATE_ROOT:-/var/lib/guiosoft-k3s-backup/consistent}"
RUN_DIR="${1:-}"
OUT="${2:-}"
die(){ echo "error: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run as root"
[[ -n "$RUN_DIR" ]] || {
  RUN_DIR="$(find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2- | while read -r d; do grep -qx 'result=PASS' "$d/metadata" 2>/dev/null && { echo "$d"; break; }; done)"
}
[[ -n "$RUN_DIR" && -s "$RUN_DIR/metadata" ]] || die "verified consistent recovery set not found"
[[ -n "$OUT" ]] || OUT="recovery-set-$(basename "$RUN_DIR").metadata"
[[ ! -e "$OUT" ]] || die "output already exists: $OUT"

declare -A M=()
while IFS='=' read -r k v; do [[ -n "$k" ]] && M["$k"]="$v"; done <"$RUN_DIR/metadata"
[[ "${M[format]:-}" == guiosoft-k3s-consistent-backup-v2 ]] || die "unsupported recovery-set metadata format"
[[ "${M[result]:-}" == PASS ]] || die "recovery set is not PASS"
for k in backup_set_id hostname quiesced_at control_plane_archive control_plane_restic_snapshot_id control_plane_restic_snapshot_time pv_restic_snapshot_id pv_restic_snapshot_time completed_backup_window_at consistency_window_seconds writers_restored_at; do
  [[ -n "${M[$k]:-}" ]] || die "metadata field missing: $k"
done

cat >"$OUT" <<EOF
format=guiosoft-k3s-portable-recovery-set-v1
backup_set_id=${M[backup_set_id]}
source_hostname=${M[hostname]}
quiesced_at=${M[quiesced_at]}
control_plane_archive=${M[control_plane_archive]}
control_plane_restic_snapshot_id=${M[control_plane_restic_snapshot_id]}
control_plane_restic_snapshot_time=${M[control_plane_restic_snapshot_time]}
pv_restic_snapshot_id=${M[pv_restic_snapshot_id]}
pv_restic_snapshot_time=${M[pv_restic_snapshot_time]}
completed_backup_window_at=${M[completed_backup_window_at]}
consistency_window_seconds=${M[consistency_window_seconds]}
writers_restored_at=${M[writers_restored_at]}
EOF
chmod 0600 "$OUT"
echo "Portable recovery-set metadata exported: $OUT"
echo "backup_set_id=${M[backup_set_id]}"
