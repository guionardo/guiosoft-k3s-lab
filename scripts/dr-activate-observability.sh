#!/usr/bin/env bash
set -euo pipefail
MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"
ISOLATION_TABLE="${DR_ISOLATION_TABLE:-dr_isolation}"
CONFIG="${K3S_CONFIG:-/etc/rancher/k3s/config.yaml}"
TARGET_NODE="${DR_PV_TARGET_NODE:-$(hostname -s)}"
NAMESPACE="${DR_OBSERVABILITY_NAMESPACE:-monitoring}"
CONFIRM_EXPECTED="activate-isolated-observability"
fail(){ echo "error: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "run as root"
[[ "${DR_ACTIVATE_CONFIRM:-}" == "$CONFIRM_EXPECTED" ]] || fail "set DR_ACTIVATE_CONFIRM=$CONFIRM_EXPECTED"
[[ -s "$MARKER_FILE" ]] && grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" || fail "invalid DR target marker"
nft list table inet "$ISOLATION_TABLE" >/dev/null 2>&1 || fail "DR WAN isolation inactive"
command -v k3s >/dev/null || fail "k3s missing"
command -v python3 >/dev/null || fail "python3 missing"
K="k3s kubectl"
$K get --raw=/readyz >/dev/null 2>&1 || fail "K3s API not ready"

# Prove restored desired state remains neutralized before local execution.
for kind in gitrepositories.source.toolkit.fluxcd.io kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io; do
  bad="$($K get "$kind" -A -o json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(" ".join(i["metadata"]["name"] for i in d.get("items",[]) if i.get("spec",{}).get("suspend") is not True))' 2>/dev/null || true)"
  [[ -z "$bad" ]] || fail "$kind has unsuspended resources: $bad"
done
cf="$($K -n cloudflare get deploy cloudflared -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
[[ -z "$cf" || "$cf" == 0 ]] || fail "cloudflared replicas=$cf"

# Controller identities are deliberate and match the committed Helm values:
# Tempo, Loki and Grafana use StatefulSets; Prometheus is operator-managed via
# its StatefulSet. Refuse controller drift rather than starting a substitute.
controllers=(
  "statefulset/tempo"
  "statefulset/loki"
  "statefulset/prometheus-kube-prometheus-stack-prometheus"
  "statefulset/kube-prometheus-stack-grafana"
)
for controller in "${controllers[@]}"; do $K -n "$NAMESPACE" get "$controller" >/dev/null 2>&1 || fail "expected persistent controller missing: $NAMESPACE/$controller"; done
# The PV remap must already be complete before any writer is allowed to start.
pvcs=(storage-tempo-0 prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0 storage-loki-0 storage-kube-prometheus-stack-grafana-0)
for pvc in "${pvcs[@]}"; do
  phase="$($K -n "$NAMESPACE" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase" == Bound ]] || fail "PVC not Bound: $NAMESPACE/$pvc phase=$phase"
  pv="$($K -n "$NAMESPACE" get pvc "$pvc" -o jsonpath='{.spec.volumeName}')"
  node="$($K get pv "$pv" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[?(@.key=="kubernetes.io/hostname")].values[0]}')"
  [[ "$node" == "$TARGET_NODE" ]] || fail "PV $pv targets $node, expected $TARGET_NODE"
done
[[ -n "$(find /var/lib/rancher/k3s/agent/images -maxdepth 1 -type f -name '*.tar' -print -quit 2>/dev/null)" ]] || fail "OCI preload missing"

# Remove only disable-agent; preserve all other K3s settings and a local safety copy.
if grep -Eq '^[[:space:]]*disable-agent:[[:space:]]*true([[:space:]]*#.*)?$' "$CONFIG"; then
  cp -a "$CONFIG" "${CONFIG}.pre-dr-activate"
  sed -i -E '/^[[:space:]]*disable-agent:[[:space:]]*true([[:space:]]*#.*)?$/d' "$CONFIG"
  systemctl restart k3s
else
  fail "disable-agent:true not present; refusing ambiguous activation state"
fi
for _ in $(seq 1 60); do $K get --raw=/readyz >/dev/null 2>&1 && $K get node "$TARGET_NODE" >/dev/null 2>&1 && break; sleep 2; done
$K get --raw=/readyz >/dev/null 2>&1 || fail "K3s API did not recover"
$K wait --for=condition=Ready "node/$TARGET_NODE" --timeout=120s || fail "target node not Ready"

for controller in "${controllers[@]}"; do $K -n "$NAMESPACE" scale "$controller" --replicas=1; done
for pod in tempo-0 loki-0 prometheus-kube-prometheus-stack-prometheus-0 kube-prometheus-stack-grafana-0; do
  $K -n "$NAMESPACE" wait --for=condition=Ready "pod/$pod" --timeout=300s || fail "persistent workload not Ready: $pod"
done

# Reassert the safety boundary after agent/workload activation.
nft list table inet "$ISOLATION_TABLE" >/dev/null 2>&1 || fail "WAN isolation disappeared"
cf="$($K -n cloudflare get deploy cloudflared -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
[[ -z "$cf" || "$cf" == 0 ]] || fail "cloudflared unexpectedly active"
for kind in gitrepositories.source.toolkit.fluxcd.io kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io; do
  bad="$($K get "$kind" -A -o json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(" ".join(i["metadata"]["name"] for i in d.get("items",[]) if i.get("spec",{}).get("suspend") is not True))' 2>/dev/null || true)"
  [[ -z "$bad" ]] || fail "$kind became unsuspended: $bad"
done
echo "Approved persistent observability workloads activated on isolated DR target."
