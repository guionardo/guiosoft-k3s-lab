#!/usr/bin/env bash
set -euo pipefail
D="${1:-}"; die(){ echo "error: $*" >&2; exit 1; }; get(){ awk -F= -v k="$2" '$1==k{print substr($0,length(k)+2)}' "$1"; }
[[ -n "$D" && -d "$D" ]] || die "usage: $0 materialized-recovery-set-dir"
M="$D/MANIFEST"; R="$D/recovery-set.metadata"; [[ -s "$M" && -s "$R" ]] || die "manifest/recovery metadata missing"
grep -qx 'format=guiosoft-k3s-materialized-recovery-set-v1' "$M" || die "unsupported materialization manifest"
grep -qx 'format=guiosoft-k3s-portable-recovery-set-v1' "$R" || die "unsupported recovery-set metadata"
SET="$(get "$M" backup_set_id)"; CP="$(get "$M" control_plane_archive)"; PV="$(get "$M" pv_archive)"; CPID="$(get "$M" control_plane_restic_snapshot_id)"; PVID="$(get "$M" pv_restic_snapshot_id)"
[[ "$SET" == "$(get "$R" backup_set_id)" ]] || die "backup_set_id mismatch"
[[ "$CP" == "$(get "$R" control_plane_archive)" ]] || die "control-plane archive mismatch"
[[ "$CPID" == "$(get "$R" control_plane_restic_snapshot_id)" ]] || die "control-plane snapshot mismatch"
[[ "$PVID" == "$(get "$R" pv_restic_snapshot_id)" ]] || die "PV snapshot mismatch"
[[ "$CPID" =~ ^[0-9a-f]{64}$ && "$PVID" =~ ^[0-9a-f]{64}$ ]] || die "invalid snapshot IDs"
CPF="$D/control-plane/$CP"; PVF="$D/persistent-volumes/$PV"; [[ -s "$CPF" && -s "$CPF.sha256" && -s "$PVF" && -s "$PVF.sha256" && -s "$PVF.metadata" ]] || die "archive/checksum/metadata missing"
(cd "$D/control-plane"; sha256sum -c "$CP.sha256" >/dev/null) || die "control-plane checksum failed"
(cd "$D/persistent-volumes"; sha256sum -c "$PV.sha256" >/dev/null) || die "PV checksum failed"
[[ "$(get "$PVF.metadata" snapshot_id)" == "$PVID" ]] || die "PV metadata snapshot mismatch"
[[ "$(get "$PVF.metadata" backup_set_id)" == "$SET" ]] || die "PV metadata recovery-set mismatch"
[[ "$(get "$PVF.metadata" snapshot_time)" == "$(get "$R" pv_restic_snapshot_time)" ]] || die "PV snapshot time mismatch"
# CP archive must be structurally readable; detailed K3s archive validation remains the bundle/recovery verifier's responsibility.
tar -tzf "$CPF" >/dev/null || die "control-plane archive unreadable"
tar -tzf "$PVF" >/dev/null || die "PV archive unreadable"
echo "Materialized recovery-set verification: PASS"
echo "backup_set_id=$SET"; echo "control_plane_snapshot=$CPID"; echo "pv_snapshot=$PVID"; echo "control_plane_archive=$CP"; echo "pv_archive=$PV"
