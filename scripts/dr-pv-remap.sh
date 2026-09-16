#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${DR_PV_NAMESPACE:-monitoring}"
TARGET_NODE="${DR_PV_TARGET_NODE:-$(hostname -s)}"
MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"
ISOLATION_TABLE="${DR_ISOLATION_TABLE:-dr_isolation}"
CONFIRM_EXPECTED="remap-isolated-pvs"
WORKDIR="${DR_PV_WORKDIR:-/var/tmp/dr-pv-remap-$(date -u +%Y%m%dT%H%M%SZ)}"

# Explicit PVC set: the transaction must never discover and delete arbitrary PVCs.
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
K="k3s kubectl"

$K get node "$TARGET_NODE" >/dev/null || fail "target node not found: $TARGET_NODE"

mkdir -p "$WORKDIR"
chmod 0700 "$WORKDIR"

# Writers must exist and be scaled to zero. This is intentionally strict.
for sts in "${WRITERS[@]}"; do
  replicas="$($K -n "$NAMESPACE" get sts "$sts" -o jsonpath='{.spec.replicas}')" || fail "writer StatefulSet missing: $sts"
  [[ "$replicas" == "0" ]] || fail "writer $sts has replicas=$replicas; expected 0"
done

# Resolve only the explicitly approved PVCs and back up their live objects.
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
printf 'namespace=%s\ntarget_node=%s\n' "$NAMESPACE" "$TARGET_NODE" >"$WORKDIR/metadata.txt"

# Protect physical local-path data before deleting any Kubernetes object.
for pv in "${PVS[@]}"; do
  $K patch pv "$pv" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
  policy="$($K get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')"
  [[ "$policy" == "Retain" ]] || fail "PV $pv did not reach Retain"
done

# Generate clean recreation manifests before deleting anything. Python parses the
# API JSON to avoid brittle text/YAML manipulation. Server-assigned metadata and
# the old claimRef UID/resourceVersion are deliberately omitted.
$K get pv "${PVS[@]}" -o json >"$WORKDIR/pvs.json"
$K -n "$NAMESPACE" get pvc "${PVCS[@]}" -o json >"$WORKDIR/pvcs.json"
python3 - "$WORKDIR" "$TARGET_NODE" <<'PY'
import json, pathlib, sys
wd=pathlib.Path(sys.argv[1]); node=sys.argv[2]
pvs=json.load(open(wd/'pvs.json'))['items']
pvcs=json.load(open(wd/'pvcs.json'))['items']
out_pv=[]; out_pvc=[]
for o in pvs:
    s=o['spec']; cr=s.get('claimRef', {})
    local=s.get('local')
    if not local or not local.get('path'):
        raise SystemExit(f"PV {o['metadata']['name']} is not a local volume")
    spec={
      'capacity':s['capacity'], 'accessModes':s['accessModes'],
      'persistentVolumeReclaimPolicy':'Retain',
      'storageClassName':s.get('storageClassName',''),
      'volumeMode':s.get('volumeMode','Filesystem'), 'local':local,
      'nodeAffinity':{'required':{'nodeSelectorTerms':[{'matchExpressions':[{
        'key':'kubernetes.io/hostname','operator':'In','values':[node]}]}]}},
      'claimRef':{'apiVersion':'v1','kind':'PersistentVolumeClaim','name':cr['name'],'namespace':cr['namespace']}
    }
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
$K -n "$NAMESPACE" delete pvc "${PVCS[@]}" --wait=true

# PV deletion may already have been requested by an earlier rehearsal. Explicitly
# request it now and wait normally; never remove pv-protection finalizers.
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
done

echo "DR PV/PVC remap completed successfully."
echo "Transaction artifacts and original manifests: $WORKDIR"
$K get pv "${PVS[@]}"
$K -n "$NAMESPACE" get pvc "${PVCS[@]}"
