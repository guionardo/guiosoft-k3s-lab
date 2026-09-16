#!/usr/bin/env bash
set -euo pipefail
MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"; ISOLATION_TABLE="${DR_ISOLATION_TABLE:-dr_isolation}"; CONFIRM_EXPECTED="activate-isolated-observability"; CONFIG="${K3S_CONFIG:-/etc/rancher/k3s/config.yaml}"; TARGET_NODE="${DR_PV_TARGET_NODE:-$(hostname -s)}"
fail(){ echo "error: $*" >&2; exit 1; }; [[ ${EUID} -eq 0 ]] || fail "run as root"; [[ "${DR_ACTIVATE_CONFIRM:-}" == "$CONFIRM_EXPECTED" ]] || fail "set DR_ACTIVATE_CONFIRM=$CONFIRM_EXPECTED"; [[ -s "$MARKER_FILE" ]] && grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" || fail "invalid DR target marker"; nft list table inet "$ISOLATION_TABLE" >/dev/null 2>&1 || fail "DR WAN isolation inactive"; command -v k3s >/dev/null || fail "k3s missing"
K="k3s kubectl"; $K get --raw=/readyz >/dev/null 2>&1 || fail "K3s API not ready"
# Prove restored state is still neutralized before enabling local execution.
for kind in gitrepositories.source.toolkit.fluxcd.io kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io; do bad="$($K get "$kind" -A -o json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(" ".join(i["metadata"]["name"] for i in d.get("items",[]) if i.get("spec",{}).get("suspend") is not True))' 2>/dev/null || true)"; [[ -z "$bad" ]] || fail "$kind has unsuspended resources: $bad"; done
cf="$($K -n cloudflare get deploy cloudflared -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"; [[ -z "$cf" || "$cf" == 0 ]] || fail "cloudflared replicas=$cf"
# Remove only the disable-agent directive; preserve every other K3s setting.
if grep -Eq '^[[:space:]]*disable-agent:[[:space:]]*true' "$CONFIG"; then cp -a "$CONFIG" "${CONFIG}.pre-dr-activate"; sed -i -E '/^[[:space:]]*disable-agent:[[:space:]]*true([[:space:]]*#.*)?$/d' "$CONFIG"; systemctl restart k3s; fi
for _ in $(seq 1 60); do $K get --raw=/readyz >/dev/null 2>&1 && $K get node "$TARGET_NODE" >/dev/null 2>&1 && break; sleep 2; done
$K get --raw=/readyz >/dev/null 2>&1 || fail "K3s API did not recover"; $K wait --for=condition=Ready "node/$TARGET_NODE" --timeout=120s || fail "target node not Ready"
# OCI archives must remain in native preload before writers start.
[[ -n "$(find /var/lib/rancher/k3s/agent/images -maxdepth 1 -type f -name '*.tar' -print -quit 2>/dev/null)" ]] || fail "OCI preload missing"
# Start exactly the four persistent data workloads validated by the rehearsal.
$K -n monitoring scale statefulset tempo --replicas=1
$K -n monitoring scale statefulset loki --replicas=1
$K -n monitoring scale statefulset prometheus-kube-prometheus-stack-prometheus --replicas=1
$K -n monitoring scale statefulset kube-prometheus-stack-grafana --replicas=1
# Grafana is normally a Deployment in kube-prometheus-stack. Support either
# controller shape without broadening activation to other monitoring workloads.
if $K -n monitoring get deploy kube-prometheus-stack-grafana >/dev/null 2>&1; then $K -n monitoring scale deploy kube-prometheus-stack-grafana --replicas=1; fi
for pod in tempo-0 loki-0 prometheus-kube-prometheus-stack-prometheus-0; do $K -n monitoring wait --for=condition=Ready "pod/$pod" --timeout=300s; done
# Grafana pod name differs by controller; wait by app label instead.
$K -n monitoring wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana --timeout=300s
# Reassert exposure/reconciliation safety after workloads are live.
nft list table inet "$ISOLATION_TABLE" >/dev/null 2>&1 || fail "WAN isolation disappeared"; cf="$($K -n cloudflare get deploy cloudflared -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"; [[ -z "$cf" || "$cf" == 0 ]] || fail "cloudflared unexpectedly active"
echo "Approved persistent observability workloads activated on isolated DR target."
