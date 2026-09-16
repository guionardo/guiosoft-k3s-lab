#!/usr/bin/env bash
set -euo pipefail

SET_ID="${1:-}"
FINAL="${2:-}"
STATE_ROOT="${K3S_CONSISTENT_BACKUP_STATE_ROOT:-/var/lib/guiosoft-k3s-backup/consistent}"
TOOLING_KIT="${DR_TOOLING_KIT:-}"
OCI_KIT="${DR_OCI_KIT:-}"
ENCRYPTED_DIR="${DR_ENCRYPTED_MATERIAL_DIR:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die(){ echo "error: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run as root"
[[ -n "$SET_ID" && "$SET_ID" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "usage: $0 BACKUP_SET_ID OUTPUT_BUNDLE"
[[ -n "$FINAL" ]] || die "output bundle path required"
[[ ! -e "$FINAL" ]] || die "output already exists: $FINAL"
[[ -d "$TOOLING_KIT" && -d "$OCI_KIT" ]] || die "DR_TOOLING_KIT and DR_OCI_KIT are required"
for s in dr-recovery-set-export.sh dr-recovery-set-materialize.sh dr-recovery-set-materialize-verify.sh dr-bundle-build.sh dr-bundle-verify.sh; do [[ -f "$SCRIPT_DIR/$s" ]] || die "missing script: $s"; done
RUN_DIR="$STATE_ROOT/$SET_ID"; [[ -s "$RUN_DIR/metadata" ]] || die "consistent recovery-set state not found: $RUN_DIR/metadata"
grep -qx 'result=PASS' "$RUN_DIR/metadata" || die "recovery set is not PASS"

PARENT="$(dirname "$FINAL")"; install -d -m 0700 "$PARENT"
WORK="$(mktemp -d "$PARENT/.dr-bundle-${SET_ID}.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
PORTABLE="$WORK/recovery-set.metadata"; MATERIAL="$WORK/materialized"; CANDIDATE="$WORK/bundle"

bash "$SCRIPT_DIR/dr-recovery-set-export.sh" "$RUN_DIR" "$PORTABLE"
[[ "$(awk -F= '$1=="backup_set_id"{print $2}' "$PORTABLE")" == "$SET_ID" ]] || die "exported recovery-set ID mismatch"
bash "$SCRIPT_DIR/dr-recovery-set-materialize.sh" "$PORTABLE" "$MATERIAL"
bash "$SCRIPT_DIR/dr-recovery-set-materialize-verify.sh" "$MATERIAL"
CP="$(awk -F= '$1=="control_plane_archive"{print $2}' "$MATERIAL/MANIFEST")"
PV="$(awk -F= '$1=="pv_archive"{print $2}' "$MATERIAL/MANIFEST")"
[[ -s "$MATERIAL/control-plane/$CP" && -s "$MATERIAL/persistent-volumes/$PV" ]] || die "materialized archives missing"

DR_TOOLING_KIT="$TOOLING_KIT" DR_OCI_KIT="$OCI_KIT" \
DR_CONTROL_PLANE_ARCHIVE="$MATERIAL/control-plane/$CP" \
DR_PV_ARCHIVE="$MATERIAL/persistent-volumes/$PV" \
DR_RECOVERY_SET_METADATA="$PORTABLE" \
DR_ENCRYPTED_MATERIAL_DIR="$ENCRYPTED_DIR" \
bash "$SCRIPT_DIR/dr-bundle-build.sh" "$CANDIDATE"

bash "$SCRIPT_DIR/dr-bundle-verify.sh" "$CANDIDATE"
[[ "$(awk -F= '$1=="backup_set_id"{print $2}' "$CANDIDATE/BUNDLE-MANIFEST")" == "$SET_ID" ]] || die "verified candidate has wrong backup_set_id"
mv "$CANDIDATE" "$FINAL"
trap - EXIT; rm -rf "$WORK"
echo "Portable DR recovery bundle published: $FINAL"
echo "backup_set_id=$SET_ID"
