#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROD_HOSTNAME="${DR_PRODUCTION_HOSTNAME:-guiosoft-info}"
PROD_IP="${DR_PRODUCTION_IP:-192.168.88.9}"
CONFIRM_EXPECTED="backup-consistent-production-state"
HOST="$(hostname -s)"
NAMESPACE="${K3S_CONSISTENT_BACKUP_NAMESPACE:-monitoring}"
WAIT_TIMEOUT="${K3S_CONSISTENT_BACKUP_WAIT_TIMEOUT:-180s}"
QUIESCE_TIMEOUT_SECONDS="${K3S_CONSISTENT_BACKUP_QUIESCE_TIMEOUT_SECONDS:-300}"
STATE_ROOT="${K3S_CONSISTENT_BACKUP_STATE_ROOT:-/var/lib/guiosoft-k3s-backup/consistent}"
BACKUP_DIR="${K3S_BACKUP_DIR:-/srv/k3s/backups/k3s}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$STATE_ROOT/$RUN_ID"
K=(k3s kubectl)
PROM_CR="kube-prometheus-stack-prometheus"
PROM_STS="prometheus-kube-prometheus-stack-prometheus"
DIRECT_WRITERS=(kube-prometheus-stack-grafana tempo loki)
WRITERS=("${DIRECT_WRITERS[@]}" "$PROM_STS")

die(){ echo "error: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "run as root"
[[ "$HOST" == "$PROD_HOSTNAME" ]] || die "refusing outside production hostname '$PROD_HOSTNAME'"
ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PROD_IP" || die "production IP $PROD_IP is not present"
[[ "${K3S_CONSISTENT_BACKUP_CONFIRM:-}" == "$CONFIRM_EXPECTED" ]] || die "set K3S_CONSISTENT_BACKUP_CONFIRM=$CONFIRM_EXPECTED"
[[ "$QUIESCE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] && (( QUIESCE_TIMEOUT_SECONDS >= 60 )) || die "invalid quiesce timeout"
for cmd in k3s restic python3; do command -v "$cmd" >/dev/null || die "$cmd not found"; done
for script in k3s-backup.sh k3s-backup-verify.sh restic-r2-sync.sh k3s-pv-backup-r2.sh; do [[ -s "$REPO_ROOT/scripts/$script" ]] || die "required script missing: $script"; done
"${K[@]}" get --raw=/readyz >/dev/null || die "K3s API not ready"
"${K[@]}" -n "$NAMESPACE" get prometheus "$PROM_CR" >/dev/null || die "Prometheus CR missing: $PROM_CR"
install -d -m 0700 "$RUN_DIR"

restore_writers(){
  local rc=$? failed=0
  trap - EXIT INT TERM
  echo "Restoring production writer replicas..."
  prom_replicas="$(cat "$RUN_DIR/prometheus.replicas" 2>/dev/null || true)"
  if [[ "$prom_replicas" =~ ^[0-9]+$ ]]; then "${K[@]}" -n "$NAMESPACE" patch prometheus "$PROM_CR" --type=merge -p "{\"spec\":{\"replicas\":$prom_replicas}}" >/dev/null || failed=1; else echo "CRITICAL: missing saved Prometheus CR replica count" >&2; failed=1; fi
  for sts in "${DIRECT_WRITERS[@]}"; do
    replicas="$(awk -v n="$sts" '$1==n {print $2}' "$RUN_DIR/writers.tsv" 2>/dev/null || true)"
    [[ "$replicas" =~ ^[0-9]+$ ]] || { echo "CRITICAL: missing saved replica count for $sts" >&2; failed=1; continue; }
    "${K[@]}" -n "$NAMESPACE" scale statefulset "$sts" --replicas="$replicas" >/dev/null || failed=1
  done
  for sts in "${WRITERS[@]}"; do "${K[@]}" -n "$NAMESPACE" rollout status statefulset "$sts" --timeout="$WAIT_TIMEOUT" || failed=1; done
  printf 'writers_restored_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$RUN_DIR/metadata"
  if (( failed )); then printf 'result=FAILED_WRITER_RESTORE\n' >>"$RUN_DIR/metadata"; return 1; fi
  if (( rc != 0 )); then printf 'result=FAILED_BACKUP\n' >>"$RUN_DIR/metadata"; return "$rc"; fi
  printf 'result=PASS\n' >>"$RUN_DIR/metadata"
}
trap restore_writers EXIT INT TERM

: >"$RUN_DIR/writers.tsv"
for sts in "${DIRECT_WRITERS[@]}"; do replicas="$("${K[@]}" -n "$NAMESPACE" get statefulset "$sts" -o jsonpath='{.spec.replicas}')" || die "writer missing: $sts"; [[ "$replicas" =~ ^[0-9]+$ ]] || die "invalid replicas for $sts: $replicas"; printf '%s\t%s\n' "$sts" "$replicas" >>"$RUN_DIR/writers.tsv"; done
PROM_REPLICAS="$("${K[@]}" -n "$NAMESPACE" get prometheus "$PROM_CR" -o jsonpath='{.spec.replicas}')"; [[ "$PROM_REPLICAS" =~ ^[0-9]+$ ]] || die "invalid Prometheus CR replicas: $PROM_REPLICAS"; printf '%s\n' "$PROM_REPLICAS" >"$RUN_DIR/prometheus.replicas"
chmod 0600 "$RUN_DIR/writers.tsv" "$RUN_DIR/prometheus.replicas"
cat >"$RUN_DIR/metadata" <<EOF
format=guiosoft-k3s-consistent-backup-v2
backup_set_id=$RUN_ID
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
hostname=$HOST
prometheus_original_replicas=$PROM_REPLICAS
EOF
chmod 0600 "$RUN_DIR/metadata"

echo "Quiescing persistent writers (graceful timeout ${QUIESCE_TIMEOUT_SECONDS}s)..."
for sts in "${DIRECT_WRITERS[@]}"; do "${K[@]}" -n "$NAMESPACE" scale statefulset "$sts" --replicas=0 >/dev/null; done
"${K[@]}" -n "$NAMESPACE" patch prometheus "$PROM_CR" --type=merge -p '{"spec":{"replicas":0}}' >/dev/null
QUIESCE_DEADLINE=$(( $(date +%s) + QUIESCE_TIMEOUT_SECONDS ))
for sts in "${WRITERS[@]}"; do while :; do pods="$("${K[@]}" -n "$NAMESPACE" get pods -o json | python3 -c 'import json,sys; n=sys.argv[1]; d=json.load(sys.stdin); print(sum(any(o.get("kind")=="StatefulSet" and o.get("name")==n for o in p["metadata"].get("ownerReferences",[])) for p in d["items"]))' "$sts")"; [[ "$pods" == 0 ]] && break; if (( $(date +%s) >= QUIESCE_DEADLINE )); then echo "error: graceful quiesce timed out for $sts; refusing to force-delete pods" >&2; "${K[@]}" -n "$NAMESPACE" get pods -o wide >&2 || true; die "writer pods still present for $sts after ${QUIESCE_TIMEOUT_SECONDS}s"; fi; sleep 2; done; done
[[ "$("${K[@]}" -n "$NAMESPACE" get prometheus "$PROM_CR" -o jsonpath='{.spec.replicas}')" == 0 ]] || die "Prometheus CR did not remain at replicas=0"
QUIESCED_EPOCH="$(date +%s)"; printf 'quiesced_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$RUN_DIR/metadata"

before_list="$RUN_DIR/control-plane.before"; after_list="$RUN_DIR/control-plane.after"
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'k3s-*.tar.gz' -printf '%p\n' | sort >"$before_list"
bash "$REPO_ROOT/scripts/k3s-backup.sh"
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'k3s-*.tar.gz' -printf '%p\n' | sort >"$after_list"
CP_ARCHIVE="$(comm -13 "$before_list" "$after_list" | tail -n1)"; [[ -n "$CP_ARCHIVE" && -f "$CP_ARCHIVE" ]] || die "could not identify newly-created control-plane archive"
bash "$REPO_ROOT/scripts/k3s-backup-verify.sh" "$CP_ARCHIVE"
bash "$REPO_ROOT/scripts/restic-r2-sync.sh" "$CP_ARCHIVE"

set -a
# shellcheck disable=SC1091
source /etc/k3s-backup/r2.env
set +a
export RESTIC_REPOSITORY_FILE=/etc/k3s-backup/restic.repository
export RESTIC_PASSWORD_FILE=/etc/k3s-backup/restic.password
CP_BASE="$(basename "$CP_ARCHIVE")"
# Do not infer identity from --latest: local staging may resolve through a different
# canonical mount path. Find the exact snapshot by the archive basename it contains.
CP_SNAPSHOT=""; CP_TIME=""
while IFS=$'\t' read -r sid stime; do
  if restic ls "$sid" 2>/dev/null | awk '{print $NF}' | grep -Fqx "/mnt/store2/k3s/backups/k3s/$CP_BASE" || restic ls "$sid" 2>/dev/null | awk '{print $NF}' | grep -Fqx "/srv/k3s/backups/k3s/$CP_BASE"; then CP_SNAPSHOT="$sid"; CP_TIME="$stime"; break; fi
done < <(restic snapshots --host "$HOST" --tag k3s-control-plane --json | python3 -c 'import json,sys,datetime; x=json.load(sys.stdin); x.sort(key=lambda v:datetime.datetime.fromisoformat(v["time"].replace("Z","+00:00")),reverse=True); [print(v["id"]+"\t"+v["time"]) for v in x]')
[[ -n "$CP_SNAPSHOT" ]] || die "could not resolve control-plane Restic snapshot containing $CP_BASE"
echo "Resolved control-plane snapshot: ${CP_SNAPSHOT:0:8} ($CP_TIME)"

PV_OUTPUT="$RUN_DIR/pv-backup.out"
env K3S_PV_BACKUP_CONFIRM=backup-production-pvs bash "$REPO_ROOT/scripts/k3s-pv-backup-r2.sh" | tee "$PV_OUTPUT"
PV_SNAPSHOT="$(awk -F= '$1=="snapshot_id"{print $2;exit}' "$PV_OUTPUT")"; PV_TIME="$(awk -F= '$1=="snapshot_time"{print $2;exit}' "$PV_OUTPUT")"; [[ -n "$PV_SNAPSHOT" && -n "$PV_TIME" ]] || die "PV backup did not report snapshot identity"
COMPLETED_EPOCH="$(date +%s)"
cat >>"$RUN_DIR/metadata" <<EOF
control_plane_archive=$CP_BASE
control_plane_restic_snapshot_id=$CP_SNAPSHOT
control_plane_restic_snapshot_time=$CP_TIME
pv_restic_snapshot_id=$PV_SNAPSHOT
pv_restic_snapshot_time=$PV_TIME
completed_backup_window_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
consistency_window_seconds=$((COMPLETED_EPOCH-QUIESCED_EPOCH))
EOF

echo "Backup set verified. Writers will now be restored by the safety trap."
echo "backup_set_id=$RUN_ID"
echo "state=$RUN_DIR"
