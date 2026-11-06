#!/usr/bin/env bash
set -euo pipefail

PV_ROOT="${K3S_PV_ROOT:-/mnt/store1/k3s/local-path}"
TAG="${K3S_PV_RESTIC_TAG:-k3s-persistent-volumes}"
PROD_HOSTNAME="${DR_PRODUCTION_HOSTNAME:-guiosoft-info}"
PROD_IP="${DR_PRODUCTION_IP:-192.168.88.9}"
RESTIC_ENV="${RESTIC_R2_ENV:-/etc/k3s-backup/r2.env}"
RESTIC_PASSWORD_PATH="${K3S_PV_RESTIC_PASSWORD_FILE:-/etc/k3s-backup/restic.password}"
RESTIC_REPOSITORY_PATH="${K3S_PV_RESTIC_REPOSITORY_FILE:-/etc/k3s-backup/restic.repository}"
SKIP_CHECK="${K3S_PV_RESTIC_SKIP_CHECK:-0}"
CONFIRM_EXPECTED="backup-production-pvs"
HOST="$(hostname -s)"

[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ "$HOST" == "$PROD_HOSTNAME" ]] || { echo "error: refusing PV export outside production hostname '$PROD_HOSTNAME'" >&2; exit 1; }
ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PROD_IP" || { echo "error: production IP $PROD_IP is not present" >&2; exit 1; }
[[ "${K3S_PV_BACKUP_CONFIRM:-}" == "$CONFIRM_EXPECTED" ]] || { echo "error: explicit confirmation required: K3S_PV_BACKUP_CONFIRM=$CONFIRM_EXPECTED" >&2; exit 1; }
[[ "$SKIP_CHECK" == 0 || "$SKIP_CHECK" == 1 ]] || { echo "error: K3S_PV_RESTIC_SKIP_CHECK must be 0 or 1" >&2; exit 1; }
[[ -d "$PV_ROOT" ]] || { echo "error: PV root not found: $PV_ROOT" >&2; exit 1; }
for f in "$RESTIC_ENV" "$RESTIC_PASSWORD_PATH" "$RESTIC_REPOSITORY_PATH"; do [[ -s "$f" ]] || { echo "error: required Restic runtime file missing: $f" >&2; exit 1; }; done
command -v restic >/dev/null || { echo "error: restic not installed" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not installed" >&2; exit 1; }

KUBECTL=(k3s kubectl -n monitoring)
writers=(kube-prometheus-stack-grafana tempo loki prometheus-kube-prometheus-stack-prometheus)
for sts in "${writers[@]}"; do
  replicas="$("${KUBECTL[@]}" get statefulset "$sts" -o jsonpath='{.spec.replicas}')"
  [[ "${replicas:-0}" == "0" ]] || { echo "error: writer StatefulSet $sts has replicas=$replicas; refusing inconsistent backup" >&2; exit 1; }
done

# registry-data is a disposable cache rebuildable from git: keep its PV directory out of the snapshot.
REGISTRY_DIR=""
registry_pv=""
if ! registry_pv="$(k3s kubectl -n registry get pvc registry-data -o jsonpath='{.spec.volumeName}' 2>&1)"; then
  [[ "$registry_pv" == *"(NotFound)"* ]] || { echo "error: unable to resolve registry cache PVC registry/registry-data: $registry_pv" >&2; exit 1; }
  echo "registry cache PVC absent; nothing to exclude"
else
  registry_dir=""
  if ! registry_dir="$(k3s kubectl get pv "$registry_pv" -o jsonpath='{.spec.local.path}' 2>&1)"; then
    echo "error: unable to resolve registry cache PV $registry_pv: $registry_dir" >&2; exit 1
  fi
  [[ "$registry_dir" == "$PV_ROOT/"?* ]] || { echo "error: registry PV path '$registry_dir' is not under $PV_ROOT; refusing inconsistent backup" >&2; exit 1; }
  REGISTRY_DIR="$registry_dir"
fi

set -a
# shellcheck disable=SC1090
source "$RESTIC_ENV"
set +a
unset RESTIC_REPOSITORY_FILE RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_PATH"
export RESTIC_REPOSITORY_FILE="$RESTIC_REPOSITORY_PATH"

restic snapshots >/dev/null
backup_cmd=(restic backup "$PV_ROOT" --tag "$TAG" --host "$HOST")
if [[ -n "$REGISTRY_DIR" ]]; then backup_cmd+=(--exclude "$REGISTRY_DIR"); fi
"${backup_cmd[@]}"
if [[ "$SKIP_CHECK" == 1 ]]; then
  echo "Full Restic repository check deferred by K3S_PV_RESTIC_SKIP_CHECK=1."
else
  restic check
fi
snapshot_json="$(restic snapshots --host "$HOST" --tag "$TAG" --json | python3 -c 'import json,sys,datetime; x=json.load(sys.stdin); s=max(x,key=lambda v:datetime.datetime.fromisoformat(v["time"].replace("Z","+00:00"))) if x else None; print(json.dumps({"id":s["id"],"time":s["time"]}) if s else "")')"
[[ -n "$snapshot_json" ]] || { echo "error: unable to resolve created PV snapshot" >&2; exit 1; }
snapshot_id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$snapshot_json")"
snapshot_time="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["time"])' "$snapshot_json")"

echo "Persistent-volume backup completed."
echo "tag=$TAG"
echo "path=$PV_ROOT"
echo "exclude=${REGISTRY_DIR:-none}"
echo "host=$HOST"
echo "snapshot_id=$snapshot_id"
echo "snapshot_time=$snapshot_time"
