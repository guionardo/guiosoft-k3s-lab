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
WRITERS=(tempo prometheus-kube-prometheus-stack-prometheus loki kube-prometheus-stack-grafana)

fail(){ echo "error: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "run as root"
[[ "${DR_PV_REMAP_CONFIRM:-}" == "$CONFIRM_EXPECTED" ]] || fail "set DR_PV_REMAP_CONFIRM=$CONFIRM_EXPECTED"
[[ -s "$MARKER_FILE" ]] || fail "DR marker missing"
grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" || fail "invalid DR marker"
nft list table inet "$ISOLATION_TABLE" >/dev/null 2>&1 || fail "DR WAN isolation inactive"
command -v k3s >/dev/null || fail "k3s missing"
command -v python3 >/dev/null || fail "python3 missing"
K="k3s kubectl"
[[ -n "$TARGET_NODE" ]] || fail "target node name missing"
[[ "$TARGET_NODE" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || fail "invalid target node name: $TARGET_NODE"
[[ -d "$TARGET_ROOT" ]] || fail "target storage root missing"
mkdir -p "$WORKDIR"
chmod 0700 "$WORKDIR"

# During the isolated restore phase disable-agent:true is mandatory. The target
# node therefore does not exist in the restored API yet. PV nodeAffinity may
# safely reference the future hostname; activation later registers that node.
for sts in "${WRITERS[@]}"; do
  replicas="$($K -n "$NAMESPACE" get sts "$sts" -o jsonpath='{.spec.replicas}')" || fail "writer missing: $sts"
  [[ "$replicas" == 0 ]] || fail "writer $sts replicas=$replicas expected=0"
done

PVS=()
for pvc in "${PVCS[@]}"; do
  pv="$($K -n "$NAMESPACE" get pvc "$pvc" -o jsonpath='{.spec.volumeName}')" || fail "PVC missing: $pvc"
  [[ -n "$pv" ]] || fail "PVC unbound: $pvc"
  PVS+=("$pv")
  $K -n "$NAMESPACE" get pvc "$pvc" -o yaml >"$WORKDIR/pvc-$pvc.yaml"
  $K get pv "$pv" -o yaml >"$WORKDIR/pv-$pv.yaml"
done

for pv in "${PVS[@]}"; do
  $K patch pv "$pv" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
done
$K get pv "${PVS[@]}" -o json >"$WORKDIR/pvs.json"
$K -n "$NAMESPACE" get pvc "${PVCS[@]}" -o json >"$WORKDIR/pvcs.json"

python3 - "$WORKDIR" "$TARGET_NODE" "$SOURCE_ROOT" "$TARGET_ROOT" <<'PY'
import json,pathlib,sys
wd=pathlib.Path(sys.argv[1]); node=sys.argv[2]; src=sys.argv[3].rstrip('/'); dst=sys.argv[4].rstrip('/'); pvs=json.load(open(wd/'pvs.json'))['items']; pvcs=json.load(open(wd/'pvcs.json'))['items']; op=[]; oc=[]
for o in pvs:
 s=o['spec']; old=s.get('local',{}).get('path','').rstrip('/'); prefix=src+'/'
 if not old.startswith(prefix): raise SystemExit(f"PV {o['metadata']['name']} path outside source root: {old}")
 rel=old[len(prefix):]
 if not rel or '/' in rel or rel in {'.','..'}: raise SystemExit(f"unexpected local path: {rel}")
 new=f'{dst}/{rel}'
 if not pathlib.Path(new).is_dir(): raise SystemExit(f'restored PV directory missing: {new}')
 spec={'capacity':s['capacity'],'accessModes':s['accessModes'],'persistentVolumeReclaimPolicy':'Retain','storageClassName':s.get('storageClassName',''),'volumeMode':s.get('volumeMode','Filesystem'),'local':{'path':new},'nodeAffinity':{'required':{'nodeSelectorTerms':[{'matchExpressions':[{'key':'kubernetes.io/hostname','operator':'In','values':[node]}]}]}}}
 op.append({'apiVersion':'v1','kind':'PersistentVolume','metadata':{'name':o['metadata']['name']},'spec':spec})
for o in pvcs:
 s=o['spec']; spec={'accessModes':s['accessModes'],'resources':{'requests':s['resources']['requests']},'storageClassName':s.get('storageClassName',''),'volumeMode':s.get('volumeMode','Filesystem'),'volumeName':s['volumeName']}; oc.append({'apiVersion':'v1','kind':'PersistentVolumeClaim','metadata':{'name':o['metadata']['name'],'namespace':o['metadata']['namespace']},'spec':spec})
json.dump({'apiVersion':'v1','kind':'List','items':op},open(wd/'recreate-pvs.json','w'),indent=2); json.dump({'apiVersion':'v1','kind':'List','items':oc},open(wd/'recreate-pvcs.json','w'),indent=2)
PY

$K apply --dry-run=client -f "$WORKDIR/recreate-pvs.json" >/dev/null
$K apply --dry-run=client -f "$WORKDIR/recreate-pvcs.json" >/dev/null
$K -n "$NAMESPACE" get pods -o json >"$WORKDIR/pods.json"
blocking_pods="$(python3 - "$WORKDIR/pods.json" "${PVCS[@]}" <<'PY'
import json,sys
claims=set(sys.argv[2:]); data=json.load(open(sys.argv[1]))
for pod in data.get('items',[]):
 used={v.get('persistentVolumeClaim',{}).get('claimName') for v in pod.get('spec',{}).get('volumes',[])}
 if claims & used and pod.get('metadata',{}).get('deletionTimestamp'): print(pod['metadata']['name'])
PY
)"
if [[ -n "$blocking_pods" ]]; then
  echo "error: Terminating restored pods reference protected PVCs:" >&2
  printf '  %s\n' $blocking_pods >&2
  echo "Force-delete only these verified orphaned restored pods, then rerun." >&2
  exit 1
fi

$K -n "$NAMESPACE" delete pvc "${PVCS[@]}" --wait=true
$K delete pv "${PVS[@]}" --wait=true
$K create -f "$WORKDIR/recreate-pvs.json"
$K create -f "$WORKDIR/recreate-pvcs.json"

for pvc in "${PVCS[@]}"; do
  $K -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Bound "pvc/$pvc" --timeout=60s
  pv="$($K -n "$NAMESPACE" get pvc "$pvc" -o jsonpath='{.spec.volumeName}')"
  uid="$($K -n "$NAMESPACE" get pvc "$pvc" -o jsonpath='{.metadata.uid}')"
  [[ "$uid" == "$($K get pv "$pv" -o jsonpath='{.spec.claimRef.uid}')" ]] || fail "UID mismatch $pvc"
  [[ "$($K get pv "$pv" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[?(@.key=="kubernetes.io/hostname")].values[0]}')" == "$TARGET_NODE" ]] || fail "affinity mismatch $pv"
  path="$($K get pv "$pv" -o jsonpath='{.spec.local.path}')"
  [[ "$path" == "$TARGET_ROOT/"* && -d "$path" ]] || fail "invalid physical path $pv: $path"
done

echo "DR PV/PVC remap completed successfully. artifacts=$WORKDIR"
