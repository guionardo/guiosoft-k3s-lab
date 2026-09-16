#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROD_HOSTNAME="${DR_PRODUCTION_HOSTNAME:-guiosoft-info}"
PROD_IP="${DR_PRODUCTION_IP:-192.168.88.9}"
CONFIRM_EXPECTED="backup-consistent-production-state"
HOST="$(hostname -s)"
NAMESPACE="${K3S_CONSISTENT_BACKUP_NAMESPACE:-monitoring}"
WAIT_TIMEOUT="${K3S_CONSISTENT_BACKUP_WAIT_TIMEOUT:-180s}"
STATE_ROOT="${K3S_CONSISTENT_BACKUP_STATE_ROOT:-/var/lib/guiosoft-k3s-backup/consistent}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$STATE_ROOT/$RUN_ID"
K=(k3s kubectl)
WRITERS=(
  kube-prometheus-stack-grafana
  tempo
  loki
  prometheus-kube-prometheus-stack-prometheus
)

die(){ echo "error: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die "run as root"
[[ "$HOST" == "$PROD_HOSTNAME" ]] || die "refusing outside production hostname '$PROD_HOSTNAME'"
ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PROD_IP" || die "production IP $PROD_IP is not present"
[[ "${K3S_CONSISTENT_BACKUP_CONFIRM:-}" == "$CONFIRM_EXPECTED" ]] || die "set K3S_CONSISTENT_BACKUP_CONFIRM=$CONFIRM_EXPECTED"
for cmd in k3s restic python3; do command -v "$cmd" >/dev/null || die "$cmd not found"; done
for script in k3s-backup.sh k3s-backup-verify.sh restic-r2-sync.sh k3s-pv-backup-r2.sh; do [[ -s "$REPO_ROOT/scripts/$script" ]] || die "required script missing: $script"; done
"${K[@]}" get --raw=/readyz >/dev/null || die "K3s API not ready"
install -d -m 0700 "$RUN_DIR"

restore_writers(){
  local rc=$? failed=0
  trap - EXIT INT TERM
  echo "Restoring production writer replicas..."
  for sts in "${WRITERS[@]}"; do
    replicas="$(awk -v n="$sts" '$1==n {print $2}' "$RUN_DIR/writers.tsv" 2>/dev/null || true)"
    [[ "$replicas" =~ ^[0-9]+$ ]] || { echo "warning: missing saved replica count for $sts" >&2; failed=1; continue; }
    "${K[@]}" -n "$NAMESPACE" scale statefulset "$sts" --replicas="$replicas" >/dev/null || failed=1
  done
  for sts in "${WRITERS[@]}"; do
    replicas="$(awk -v n="$sts" '$1==n {print $2}' "$RUN_DIR/writers.tsv" 2>/dev/null || true)"
    if [[ "$replicas" =~ ^[0-9]+$ ]] && (( replicas > 0 )); then
      "${K[@]}" -n "$NAMESPACE" rollout status statefulset "$sts" --timeout="$WAIT_TIMEOUT" || failed=1
    fi
  done
  if (( failed )); then
    echo "CRITICAL: production writer restoration/health verification failed" >&2
    return 1
  fi
  if (( rc != 0 )); then return "$rc"; fi
}
trap restore_writers EXIT INT TERM

: >"$RUN_DIR/writers.tsv"
for sts in "${WRITERS[@]}"; do
  replicas="$("${K[@]}" -n "$NAMESPACE" get statefulset "$sts" -o jsonpath='{.spec.replicas}')" || die "writer missing: $sts"
  [[ "$replicas" =~ ^[0-9]+$ ]] || die "invalid replicas for $sts: $replicas"
  printf '%s\t%s\n' "$sts" "$replicas" >>"$RUN_DIR/writers.tsv"
done
chmod 0600 "$RUN_DIR/writers.tsv"

cat >"$RUN_DIR/metadata" <<EOF
format=guiosoft-k3s-consistent-backup-v1
run_id=$RUN_ID
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
hostname=$HOST
EOF
chmod 0600 "$RUN_DIR/metadata"

echo "Quiescing persistent writers..."
for sts in "${WRITERS[@]}"; do "${K[@]}" -n "$NAMESPACE" scale statefulset "$sts" --replicas=0 >/dev/null; done
for sts in "${WRITERS[@]}"; do
  "${K[@]}" -n "$NAMESPACE" wait --for=jsonpath='{.status.replicas}'=0 "statefulset/$sts" --timeout="$WAIT_TIMEOUT" >/dev/null 2>&1 || true
  for _ in $(seq 1 90); do
    pods="$("${K[@]}" -n "$NAMESPACE" get pods -o json | python3 -c 'import json,sys; sts=sys.argv[1]; d=json.load(sys.stdin); print(sum(1 for p in d["items"] if any(o.get("kind")=="StatefulSet" and o.get("name")==sts for o in p["metadata"].get("ownerReferences",[]))))' "$sts")"
    [[ "$pods" == 0 ]] && break
    sleep 2
  done
  [[ "$pods" == 0 ]] || die "writer pods still present for $sts"
done
QUIESCED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'quiesced_at=%s\n' "$QUIESCED_AT" >>"$RUN_DIR/metadata"

echo "Creating control-plane backup while writers are quiesced..."
bash "$REPO_ROOT/scripts/k3s-backup.sh"
CP_ARCHIVE="$(find "${K3S_BACKUP_DIR:-/srv/k3s/backups/k3s}" -maxdepth 1 -type f -name 'k3s-*.tar.gz' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
[[ -n "$CP_ARCHIVE" ]] || die "control-plane archive not found after backup"
bash "$REPO_ROOT/scripts/k3s-backup-verify.sh" "$CP_ARCHIVE"

echo "Uploading verified control-plane backup off-host..."
bash "$REPO_ROOT/scripts/restic-r2-sync.sh"

echo "Creating and verifying persistent-volume snapshot while still quiesced..."
env K3S_PV_BACKUP_CONFIRM=backup-production-pvs bash "$REPO_ROOT/scripts/k3s-pv-backup-r2.sh"

printf 'control_plane_archive=%s\ncompleted_backup_window_at=%s\n' "$(basename "$CP_ARCHIVE")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$RUN_DIR/metadata"

echo "Consistent backup set completed. Writers will now be restored by the safety trap."
echo "run_id=$RUN_ID"
echo "state=$RUN_DIR"
