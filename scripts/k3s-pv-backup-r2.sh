#!/usr/bin/env bash
set -euo pipefail

PV_ROOT="${K3S_PV_ROOT:-/mnt/store1/k3s/local-path}"
TAG="${K3S_PV_RESTIC_TAG:-k3s-persistent-volumes}"
PROD_HOSTNAME="${DR_PRODUCTION_HOSTNAME:-guiosoft-info}"
PROD_IP="${DR_PRODUCTION_IP:-192.168.88.9}"
RESTIC_ENV="${RESTIC_R2_ENV:-/etc/k3s-backup/r2.env}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/k3s-backup/restic.password}"
RESTIC_REPOSITORY_FILE="${RESTIC_REPOSITORY_FILE:-/etc/k3s-backup/restic.repository}"
CONFIRM_EXPECTED="backup-production-pvs"
HOST="$(hostname -s)"

[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ "$HOST" == "$PROD_HOSTNAME" ]] || { echo "error: refusing PV export outside production hostname '$PROD_HOSTNAME'" >&2; exit 1; }
ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PROD_IP" || {
  echo "error: production IP $PROD_IP is not present" >&2; exit 1;
}
[[ "${K3S_PV_BACKUP_CONFIRM:-}" == "$CONFIRM_EXPECTED" ]] || {
  echo "error: explicit confirmation required: K3S_PV_BACKUP_CONFIRM=$CONFIRM_EXPECTED" >&2; exit 1;
}
[[ -d "$PV_ROOT" ]] || { echo "error: PV root not found: $PV_ROOT" >&2; exit 1; }
for f in "$RESTIC_ENV" "$RESTIC_PASSWORD_FILE" "$RESTIC_REPOSITORY_FILE"; do
  [[ -s "$f" ]] || { echo "error: required Restic runtime file missing: $f" >&2; exit 1; }
done
command -v restic >/dev/null || { echo "error: restic not installed" >&2; exit 1; }

# Consistency is deliberately external to this script. The operator/automation
# must stop the relevant writers first. This guard requires the four currently
# protected observability StatefulSets to be at zero replicas.
KUBECTL=(k3s kubectl -n monitoring)
writers=(
  kube-prometheus-stack-grafana
  tempo
  loki
  prometheus-kube-prometheus-stack-prometheus
)
for sts in "${writers[@]}"; do
  replicas="$("${KUBECTL[@]}" get statefulset "$sts" -o jsonpath='{.spec.replicas}')"
  [[ "${replicas:-0}" == "0" ]] || { echo "error: writer StatefulSet $sts has replicas=$replicas; refusing inconsistent backup" >&2; exit 1; }
done

set -a
# shellcheck disable=SC1090
source "$RESTIC_ENV"
set +a
export RESTIC_PASSWORD_FILE
export RESTIC_REPOSITORY="$(cat "$RESTIC_REPOSITORY_FILE")"

restic snapshots >/dev/null
restic backup "$PV_ROOT" --tag "$TAG" --host "$HOST"
restic check

echo "Persistent-volume backup completed and repository check passed."
echo "tag=$TAG path=$PV_ROOT host=$HOST"
