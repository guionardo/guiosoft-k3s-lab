#!/usr/bin/env bash
set -euo pipefail

META="${1:-}"
OUT="${2:-}"
CFG="${RESTIC_CONFIG_DIR:-/etc/k3s-backup}"
PV_ROOT="${K3S_PV_ROOT:-/mnt/store1/k3s/local-path}"
die(){ echo "error: $*" >&2; exit 1; }
val(){ awk -F= -v k="$1" '$1==k{print substr($0,length(k)+2)}' "$META"; }

[[ ${EUID} -eq 0 ]] || die "run as root"
[[ -s "$META" && -n "$OUT" ]] || die "usage: $0 recovery-set.metadata output-dir"
[[ ! -e "$OUT" ]] || die "output already exists: $OUT"
grep -qx 'format=guiosoft-k3s-portable-recovery-set-v1' "$META" || die "unsupported metadata"
for f in r2.env restic.password restic.repository; do [[ -s "$CFG/$f" ]] || die "missing $CFG/$f"; done
for c in restic python3 tar sha256sum; do command -v "$c" >/dev/null || die "missing command: $c"; done

SET_ID="$(val backup_set_id)"; CP_ID="$(val control_plane_restic_snapshot_id)"; PV_ID="$(val pv_restic_snapshot_id)"; CP_NAME="$(val control_plane_archive)"
[[ -n "$SET_ID" && "$CP_ID" =~ ^[0-9a-f]{64}$ && "$PV_ID" =~ ^[0-9a-f]{64}$ && -n "$CP_NAME" ]] || die "invalid recovery-set identity"

set -a; source "$CFG/r2.env"; set +a
unset RESTIC_REPOSITORY RESTIC_REPOSITORY_FILE RESTIC_PASSWORD_COMMAND
export RESTIC_REPOSITORY_FILE="$CFG/restic.repository" RESTIC_PASSWORD_FILE="$CFG/restic.password"
restic cat config >/dev/null || die "Restic preflight failed"

TMP="$(mktemp -d /var/tmp/k3s-recovery-set.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
restic snapshots --json >"$TMP/snapshots.json"
python3 - "$TMP/snapshots.json" "$CP_ID" "$PV_ID" <<'PY'
import json,sys
ids={x.get("id") for x in json.load(open(sys.argv[1]))}
missing=[x for x in sys.argv[2:] if x not in ids]
if missing: raise SystemExit("missing exact Restic snapshot(s): "+", ".join(missing))
PY

install -d -m 0700 "$OUT/control-plane" "$OUT/persistent-volumes"
cp -a "$META" "$OUT/recovery-set.metadata"

restic restore "$CP_ID" --target "$TMP/cp" >/dev/null
CP_SRC="$(find "$TMP/cp" -type f -name "$CP_NAME" -print -quit)"
[[ -n "$CP_SRC" && -s "$CP_SRC" ]] || die "control-plane archive not found in exact snapshot"
cp -a "$CP_SRC" "$OUT/control-plane/$CP_NAME"
(cd "$OUT/control-plane"; sha256sum "$CP_NAME" >"$CP_NAME.sha256"; sha256sum -c "$CP_NAME.sha256" >/dev/null)

restic restore "$PV_ID" --target "$TMP/pv" >/dev/null
PV_SRC="$TMP/pv$PV_ROOT"; [[ -d "$PV_SRC" ]] || die "PV root not found in exact snapshot"
PV_NAME="k3s-persistent-volumes-${SET_ID}-${PV_ID:0:8}.tar.gz"
tar --numeric-owner -C "$PV_SRC" -czf "$OUT/persistent-volumes/$PV_NAME" .
(cd "$OUT/persistent-volumes"; sha256sum "$PV_NAME" >"$PV_NAME.sha256"; sha256sum -c "$PV_NAME.sha256" >/dev/null)
printf 'format=k3s-pv-archive-v1\nsnapshot_id=%s\nsnapshot_time=%s\nsource_root=%s\ncreated_at=%s\nbackup_set_id=%s\n' "$PV_ID" "$(val pv_restic_snapshot_time)" "$PV_ROOT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SET_ID" >"$OUT/persistent-volumes/$PV_NAME.metadata"

cat >"$OUT/MANIFEST" <<EOF
format=guiosoft-k3s-materialized-recovery-set-v1
backup_set_id=$SET_ID
control_plane_restic_snapshot_id=$CP_ID
control_plane_archive=$CP_NAME
pv_restic_snapshot_id=$PV_ID
pv_archive=$PV_NAME
materialized_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod -R go-rwx "$OUT"
echo "Consistent recovery set materialized: $OUT"
echo "backup_set_id=$SET_ID"
echo "control_plane_archive=$OUT/control-plane/$CP_NAME"
echo "pv_archive=$OUT/persistent-volumes/$PV_NAME"
