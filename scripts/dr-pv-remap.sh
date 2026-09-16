#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${DR_PV_NAMESPACE:-monitoring}"
TARGET_NODE="${DR_PV_TARGET_NODE:-$(hostname -s)}"
SOURCE_ROOT="${DR_PV_SOURCE_ROOT:-/mnt/store1/k3s/local-path}"
TARGET_ROOT="${DR_PV_TARGET_ROOT:-/var/lib/rancher/k3s/storage}"
MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"
ISOLATION_TABLE="${DR_ISOLATION_TABLE:-dr_isolation}"
CONFIRM_EXPECTED="remap-isolated-pvs"
WORKDIR="${DR_PV_WORKDIR:-/var/tmp/dr-pv-remap-$(date -u +%Y%m%dT%H%M%SZ)}"

PVCS=(
  storage-tempo-0
  prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
  storage-loki-0
  storage-kube-prometheus-stack-grafana-0
)
WRITERS=(
  tempo
  prometheus-kube-prometheus-stack-prometheus
  loki
  kube-prometheus-stack-grafana
)

fail() { echo "error: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "run as root"
[[ "${DR_PV_REMAP_CONFIRM:-}" == "$CONFIRM_EXPECTED" ]] || fail "set DR_PV_REMAP_CONFIRM=$CONFIRM_EXPECTED"
[[ -s "$MARKER_FILE" ]] || fail "DR target marker missing: $MARKER_FILE"
grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" || fail "invalid DR target marker"
command -v nft >/dev/null || fail "nft not found"
nft list table inet "$ISOLATION_TABLE" >/dev/null 2>&1 || fail "DR WAN isolation is not active"
command -v k3s >/dev/null || fail "k3s not found"
command -v python3 >/dev/null || fail "python3 not found"
K="k3s kubectl"

$K get node "$TARGET_NODE" >/dev/null || fail "target node not found: $TARGET_NODE"
[[ -d "$TARGET_ROOT" ]] || fail "target storage root does not exist: $TARGET_ROOT"

mkdir -p "$WORKDIR"
chmod 0700 "$WORKDIR"

for sts in "${WRITERS[@]}"; do
  replicas="$($K -n "$NAMESPACE" get sts "$sts" -o jsonpath='{.spec.replicas}')" || fail "writer StatefulSet missing: $sts"
  [[ "$replicas" == "0" ]] || fail "writer $sts has replicas=$replicas; expected 0"
done

PVS=()
for pvc in "${PVCS[@]}"; do
  pv="$($K -n "$NAMESPACE" get pvc "$pvc" -o jsonpath='{.spec.volumeName}')" || fail "PVC missing: $pvc"
  [[ -n "$pv" ]] || fail "PVC is not bound: $pvc"
  PVS+=("$pv")
  $K -n "$NAMESPACE" get pvc "$pvc" -o yaml >"$WORKDIR/pvc-$pvc.yaml"
  $K get pv "$pv" -o yaml >"$WORKDIR/pv-$pv.yaml"
done

printf '%s\n' "${PVS[@]}" >"$WORKDIR/pvs.txt"
printf '%s\n' "${PVCS[@]}" >"$WORKDIR/pvcs.txt"
printf 'namespace=%s\ntarget_node=%s\nsource_root=%s\ntarget_root=%s\n' \
  "$NAMESPACE" "$TARGET_NODE" "$SOURCE_ROOT" "$TARGET_ROOT" >"$WORKDIR/metadata.txt"

for pv in "${PVS[@]}"; do
  $K patch pv "$pv" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
  policy="$($K get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')"
  [[ "$policy" == "Retain" ]] || fail "PV $pv did not reach Retain"
done

$K get pv "${PVS[@]}" -o json >"$WORKDIR/pvs.json"
$K -n "$NAMESPACE" get pvc "${PVCS[@]}" -o json >"$WORKDIR/pvcs.json"
python3 - "$WORKDIR" "$TARGET_NODE" "$SOURCE_ROOT" "$TARGET_ROOT" <<'PY'
import json, pathlib, sys
wd=pathlib.Path(sys.argv[1]); node=sys.argv[2]
source_root=sys.argv[3].rstrip('/')
target_root=sys.argv[4].rstrip('/')
pvs=json.load(open(wd/'pvs.json'))['items']
pvcs=json.load(open(wd/'pvcs.json'))['items']
out_pv=[]; out_pvc=[]
for o in pvs:
    s=o['spec']
    local=s.get('local')
    if not local or not local.get('path'):
        raise SystemExit(f"PV {o['metadata']['name']} is not a local volume")
    old_path=local['path'].rstrip('/')
    prefix=source_root + '/'
    if not old_path.startswith(prefix):
        raise SystemExit(f"PV {o['metadata']['name']} path {old_path!r} is outside expected source root {source_root!r}")
    relative=old_path[len(prefix):]
    if not relative or '/' in relative or relative in {'.','..'}:
        raise SystemExit(f"PV {o['metadata']['name']} has unexpected local-path relative name: {relative!r}")
    new_path=f"{target_root}/{relative}"
    if not pathlib.Path(new_path).is_dir():
        raise SystemExit(f"restored PV directory missing: {new_path}")
    spec={
      'capacity':s['capacity'], 'accessModes':s['accessModes'],
      'persistentVolumeReclaimPolicy':'Retain',
      'storageClassName':s.get('storageClassName',''),
      'volumeMode':s.get('volumeMode','Filesystem'),
      'local':{'path':new_path},
      'nodeAffinity':{'required':{'nodeSelectorTerms':[{'matchExpressions':[{
        'key':'kubernetes.io/hostname','operator':'In','values':[node]}]}]}}
    }
    # Deliberately omit claimRef. A restored claimRef contains the UID of the
    # production PVC and leaves a recreated PV in Released state. The PVC below
    # pins volumeName; the binding controller writes the new claimRef/UID.
    out_pv.append({'apiVersion':'v1','kind':'PersistentVolume','metadata':{'name':o['metadata']['name']},'spec':spec})
for o in pvcs:
    s=o['spec']
    spec={'accessModes':s['accessModes'],'resources':{'requests':s['resources']['requests']},
          'storageClassName':s.get('storageClassName',''),'volumeMode':s.get('volumeMode','Filesystem'),
          'volumeName':s['volumeName']}
    out_pvc.append({'apiVersion':'v1','kind':'PersistentVolumeClaim',
                    'metadata':{'name':o['metadata']['name'],'namespace':o['metadata']['namespace']},'spec':spec})
json.dump({'apiVersion':'v1','kind':'List','items':out_pv},open(wd/'recreate-pvs.json','w'),indent=2)
json.dump({'apiVersion':'v1','kind':'List','items':out_pvc},open(wd/'recreate-pvcs.json','w'),indent=2)
PY

$K apply --dry-run=client -f "$WORKDIR/recreate-pvs.json" >/dev/null
$K apply --dry-run=client -f "$WORKDIR/recreate-pvcs.json" >/dev/null

echo "Backups and validated recreation manifests: $WORKDIR"
echo "Deleting only the approved PVC set; PVs are Retain."

# Restored production pods may be stuck Terminating on an absent production
# node and keep kubernetes.io/pvc-protection on these claims. Detect this before
# deletion so the operator gets a deterministic, safe remediation instead of an
# indefinite --wait hang. Never remove PVC/PV protection finalizers directly.
blocking_pods="$($K -n "$NAMESPACE" get pods -o json | python3 - "${PVCS[@]}" <<'PY'
import json,sys
claims=set(sys.argv[1:]); data=json.load(sys.stdin)
for pod in data.get('items',[]):
    used={v.get('persistentVolumeClaim',{}).get('claimName') for v in pod.get('spec',{}).get('volumes',[])}
    if claims & used and pod.get('metadata',{}).get('deletionTimestamp'):
        print(pod['metadata']['name'])
PY
)"
if [[ -n "$blocking_pods" ]]; then
  echo "error: restored pods already Terminating still reference protected PVCs:" >&2
  printf '  %s\n' $blocking_pods >&2
  echo "These pods belong to the restored cluster state and can block PVC deletion when their original node is absent." >&2
  echo "Verify they are orphaned from the unavailable production node, then force-delete only those named pods and rerun this transaction." >&2
  exit 1
fi

$K -n "$NAMESPACE" delete pvc "${PVCS[@]}" --wait=true
$K delete pv "${PVS[@]}" --wait=true

$K create -f "$WORKDIR/recreate-pvs.json"
$K create -f "$WORKDIR/recreate-pvcs.json"

for pvc in "${PVCS[@]}"; do
  $K -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Bound "pvc/$pvc" --timeout=60s
  pv="$($K -n "$NAMESPACE" get pvc "$pvc" -o jsonpath='{.spec.volumeName}')"
  pvc_uid="$($K -n "$NAMESPACE" get pvc "$pvc" -o jsonpath='{.metadata.uid}')"
  claim_uid="$($K get pv "$pv" -o jsonpath='{.spec.claimRef.uid}')"
  [[ "$pvc_uid" == "$claim_uid" ]] || fail "UID mismatch after bind: $pvc -> $pv"
  affinity="$($K get pv "$pv" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[?(@.key=="kubernetes.io/hostname")].values[0]}')"
  [[ "$affinity" == "$TARGET_NODE" ]] || fail "PV $pv affinity is '$affinity', expected '$TARGET_NODE'"
  local_path="$($K get pv "$pv" -o jsonpath='{.spec.local.path}')"
  [[ "$local_path" == "$TARGET_ROOT/"* ]] || fail "PV $pv path is '$local_path', expected under '$TARGET_ROOT'"
  [[ -d "$local_path" ]] || fail "PV $pv physical path disappeared: $local_path"
done

echo "DR PV/PVC remap completed successfully."
echo "Transaction artifacts and original manifests: $WORKDIR"
$K get pv "${PVS[@]}"
$K -n "$NAMESPACE" get pvc "${PVCS[@]}"
