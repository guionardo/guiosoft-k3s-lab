#!/usr/bin/env bash
set -uo pipefail
STAGE="${1:-${DR_PREFLIGHT_STAGE:-isolated}}"; MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"; ISOLATION_TABLE="${DR_ISOLATION_TABLE:-dr_isolation}"; PROD_HOSTNAME="${DR_PRODUCTION_HOSTNAME:-guiosoft-info}"; PROD_IP="${DR_PRODUCTION_IP:-192.168.88.9}"; K3S_DATA_DIR="${K3S_DATA_DIR:-/var/lib/rancher/k3s}"; PV_TARGET_ROOT="${DR_PV_TARGET_ROOT:-/var/lib/rancher/k3s/storage}"; TARGET_NODE="${DR_PV_TARGET_NODE:-$(hostname -s)}"; SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; fail=0
case "$STAGE" in clean|isolated|restored|full) ;; *) echo "usage: $0 {clean|isolated|restored|full}" >&2; exit 2;; esac
ok(){ printf 'OK    %s\n' "$*"; }; bad(){ printf 'FAIL  %s\n' "$*"; fail=1; }; info(){ printf 'INFO  %s\n' "$*"; }
host="$(hostname -s)"; [[ "$host" != "$PROD_HOSTNAME" ]] && ok "hostname guard: $host" || bad "production hostname detected"
ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PROD_IP" && bad "production IP $PROD_IP detected" || ok "production IP guard"
required_scripts=(dr-target-init.sh dr-network-isolation.sh dr-restore-k3s.sh k3s-backup-verify.sh dr-neutralize.sh dr-pv-import.sh dr-pv-remap.sh dr-oci-preload.sh); for s in "${required_scripts[@]}"; do [[ -s "$SCRIPT_DIR/$s" ]] && ok "recovery dependency: $s" || bad "recovery dependency missing: $s"; done
command -v k3s >/dev/null && ok "k3s installed" || bad "k3s installed"; command -v python3 >/dev/null && ok "python3 installed" || bad "python3 installed"
marker=false; [[ -s "$MARKER_FILE" ]] && grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" && marker=true; isolated=false; command -v nft >/dev/null && nft list table inet "$ISOLATION_TABLE" >/dev/null 2>&1 && isolated=true
if [[ "$STAGE" == clean ]]; then $isolated && bad "WAN isolation unexpectedly active" || ok "WAN isolation not active yet"; [[ -d "$K3S_DATA_DIR" ]] && ok "K3s data dir" || bad "K3s data dir missing"; else $marker && ok "DR target marker" || bad "DR target marker"; $isolated && ok "WAN isolation" || bad "WAN isolation"; fi
api=false; if systemctl is-active --quiet k3s 2>/dev/null && k3s kubectl get --raw=/readyz >/dev/null 2>&1; then api=true; ok "K3s API ready"; else bad "K3s API not ready"; fi
if [[ "$STAGE" == isolated ]]; then grep -Eq '^[[:space:]]*disable-agent:[[:space:]]*true' /etc/rancher/k3s/config.yaml 2>/dev/null && ok "agentless isolation enabled" || info "disable-agent not enabled yet"; fi

if [[ "$STAGE" == restored || "$STAGE" == full ]] && $api; then
  check_suspended(){ local kind="$1" label="$2" baditems; baditems="$(k3s kubectl get "$kind" -A -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(i["metadata"]["namespace"]+"/"+i["metadata"]["name"] for i in d.get("items",[]) if i.get("spec",{}).get("suspend") is not True))' 2>/dev/null || true)"; [[ -z "$baditems" ]] && ok "$label suspended" || bad "$label not suspended: $baditems"; }
  check_zero(){ local ns="$1" kind="$2"; local offenders; offenders="$(k3s kubectl -n "$ns" get "$kind" -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(i["metadata"]["name"]+"="+str(i.get("spec",{}).get("replicas",1)) for i in d.get("items",[]) if i.get("spec",{}).get("replicas",1)!=0))' 2>/dev/null || true)"; [[ -z "$offenders" ]] && ok "$ns $kind neutralized" || bad "$ns $kind still active: $offenders"; }
  check_suspended gitrepositories.source.toolkit.fluxcd.io "Flux GitRepositories"; check_suspended kustomizations.kustomize.toolkit.fluxcd.io "Flux Kustomizations"; check_suspended helmreleases.helm.toolkit.fluxcd.io "HelmReleases"
  check_zero cloudflare deployments; check_zero firecrawl deployments; check_zero lab deployments
  # In restored stage all monitoring writers stay off. In full stage four
  # explicitly recovered workloads are expected to be running, so only the
  # DaemonSet neutralization remains mandatory here.
  if [[ "$STAGE" == restored ]]; then check_zero monitoring deployments; check_zero monitoring statefulsets; fi
  bad_ds="$(k3s kubectl -n monitoring get ds -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(i["metadata"]["name"] for i in d.get("items",[]) if i.get("spec",{}).get("template",{}).get("spec",{}).get("nodeSelector",{}).get("guiosoft.info/dr-neutralized")!="true"))' 2>/dev/null || true)"; [[ -z "$bad_ds" ]] && ok "monitoring DaemonSets neutralized" || bad "monitoring DaemonSets schedulable: $bad_ds"
fi

if [[ "$STAGE" == full ]] && $api; then
  pvs=(pvc-48b7913e-2e62-4b89-91d4-145121771818 pvc-7cf83415-c71c-473a-a4a6-8e388f86e806 pvc-7feb8dc4-5fd4-4e3f-8360-5b7006f56cf3 pvc-bbc1967b-f79d-4f3d-b6b4-27d49bf6a750)
  for pv in "${pvs[@]}"; do phase="$(k3s kubectl get pv "$pv" -o jsonpath='{.status.phase}' 2>/dev/null || true)"; path="$(k3s kubectl get pv "$pv" -o jsonpath='{.spec.local.path}' 2>/dev/null || true)"; node="$(k3s kubectl get pv "$pv" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' 2>/dev/null || true)"; [[ "$phase" == Bound && "$node" == "$TARGET_NODE" && "$path" == "$PV_TARGET_ROOT/"* && -d "$path" ]] && ok "PV $pv recovered" || bad "PV $pv invalid: phase=$phase node=$node path=$path"; done
  workloads=(tempo-0 kube-prometheus-stack-grafana-0 loki-0 prometheus-kube-prometheus-stack-prometheus-0); for pod in "${workloads[@]}"; do ready="$(k3s kubectl -n monitoring get pod "$pod" -o json 2>/dev/null | python3 -c 'import json,sys;p=json.load(sys.stdin);c=p.get("status",{}).get("containerStatuses",[]);print("true" if c and all(x.get("ready") for x in c) else "false")' 2>/dev/null || true)"; [[ "$ready" == true ]] && ok "workload ready: $pod" || bad "workload not ready: $pod"; done
  [[ -d "$K3S_DATA_DIR/agent/images" && -n "$(find "$K3S_DATA_DIR/agent/images" -maxdepth 1 -type f -name '*.tar' -print -quit 2>/dev/null)" ]] && ok "native OCI preload present" || bad "native OCI preload missing"
fi
[[ $fail -eq 0 ]] && echo "DR preflight [$STAGE]: PASS" || { echo "DR preflight [$STAGE]: FAILED"; exit 1; }
