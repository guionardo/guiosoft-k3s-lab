#!/usr/bin/env bash
set -uo pipefail

STAGE="${1:-${DR_PREFLIGHT_STAGE:-isolated}}"
MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"
ISOLATION_TABLE="${DR_ISOLATION_TABLE:-dr_isolation}"
PROD_HOSTNAME="${DR_PRODUCTION_HOSTNAME:-guiosoft-info}"
PROD_IP="${DR_PRODUCTION_IP:-192.168.88.9}"
K3S_DATA_DIR="${K3S_DATA_DIR:-/var/lib/rancher/k3s}"
PV_TARGET_ROOT="${DR_PV_TARGET_ROOT:-/var/lib/rancher/k3s/storage}"
TARGET_NODE="${DR_PV_TARGET_NODE:-$(hostname -s)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

case "$STAGE" in clean|isolated|restored|full) ;; *) echo "usage: $0 {clean|isolated|restored|full}" >&2; exit 2;; esac
ok(){ printf 'OK    %s\n' "$*"; }; bad(){ printf 'FAIL  %s\n' "$*"; fail=1; }; info(){ printf 'INFO  %s\n' "$*"; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 && ok "$1 installed" || bad "$1 installed"; }

host="$(hostname -s)"
[[ "$host" != "$PROD_HOSTNAME" ]] && ok "hostname guard: $host" || bad "production hostname detected"
if ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PROD_IP"; then bad "production IP $PROD_IP detected"; else ok "production IP guard"; fi

required_scripts=(dr-target-init.sh dr-network-isolation.sh dr-restore-k3s.sh k3s-backup-verify.sh dr-pv-import.sh dr-pv-remap.sh dr-oci-preload.sh)
for s in "${required_scripts[@]}"; do [[ -s "$SCRIPT_DIR/$s" ]] && ok "recovery dependency: $s" || bad "recovery dependency missing: $SCRIPT_DIR/$s"; done

require_cmd k3s
command -v restic >/dev/null 2>&1 && ok "restic installed" || info "restic not installed (only required for direct off-host repository access)"
command -v sops >/dev/null 2>&1 && ok "sops installed" || info "sops not installed (required when decrypting recovery material on this host)"
command -v age >/dev/null 2>&1 && ok "age installed" || info "age not installed (required when decrypting recovery material on this host)"

marker=false; [[ -s "$MARKER_FILE" ]] && grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" && marker=true
isolated=false; command -v nft >/dev/null 2>&1 && nft list table inet "$ISOLATION_TABLE" >/dev/null 2>&1 && isolated=true

if [[ "$STAGE" == clean ]]; then
  $marker && info "DR marker already present" || ok "DR marker not initialized yet"
  $isolated && bad "WAN isolation unexpectedly active in clean stage" || ok "WAN isolation not active yet"
  [[ -d "$K3S_DATA_DIR" ]] && ok "K3s data dir: $K3S_DATA_DIR" || bad "K3s data dir missing: $K3S_DATA_DIR"
else
  $marker && ok "DR target marker" || bad "DR target marker"
  $isolated && ok "WAN isolation inet/$ISOLATION_TABLE" || bad "WAN isolation"
fi

api=false
if systemctl is-active --quiet k3s 2>/dev/null && k3s kubectl get --raw=/readyz >/dev/null 2>&1; then api=true; ok "K3s API ready"; else bad "K3s API not ready"; fi

if [[ "$STAGE" == isolated ]]; then
  if grep -Eq '^[[:space:]]*disable-agent:[[:space:]]*true([[:space:]]*#.*)?$' /etc/rancher/k3s/config.yaml 2>/dev/null; then ok "agentless isolation enabled"; else info "disable-agent is not true; required immediately before production datastore restore"; fi
fi

if [[ "$STAGE" == restored || "$STAGE" == full ]] && $api; then
  # A restored production datastore must be neutralized before agents/workloads
  # are allowed to run. Treat absence of a resource as informational so this
  # remains reusable if a component is intentionally removed from production.
  src="$(k3s kubectl -n flux-system get gitrepository flux-system -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
  [[ -z "$src" ]] && info "Flux GitRepository not present" || { [[ "$src" == true ]] && ok "Flux GitRepository suspended" || bad "Flux GitRepository is not suspended"; }

  bad_flux="$(k3s kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(x["metadata"]["name"] for x in d.get("items",[]) if x.get("spec",{}).get("suspend") is not True))' 2>/dev/null || true)"
  [[ -z "$bad_flux" ]] && ok "all Flux Kustomizations suspended" || bad "unsuspended Flux Kustomizations: $bad_flux"
  bad_hr="$(k3s kubectl get helmreleases.helm.toolkit.fluxcd.io -A -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(x["metadata"]["name"] for x in d.get("items",[]) if x.get("spec",{}).get("suspend") is not True))' 2>/dev/null || true)"
  [[ -z "$bad_hr" ]] && ok "all HelmReleases suspended" || bad "unsuspended HelmReleases: $bad_hr"
  cf="$(k3s kubectl -n cloudflare get deploy cloudflared -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  [[ -z "$cf" ]] && info "cloudflared deployment not present" || { [[ "$cf" == 0 ]] && ok "cloudflared replicas=0" || bad "cloudflared replicas=$cf"; }
fi

if [[ "$STAGE" == full ]] && $api; then
  pvs=(pvc-48b7913e-2e62-4b89-91d4-145121771818 pvc-7cf83415-c71c-473a-a4a6-8e388f86e806 pvc-7feb8dc4-5fd4-4e3f-8360-5b7006f56cf3 pvc-bbc1967b-f79d-4f3d-b6b4-27d49bf6a750)
  for pv in "${pvs[@]}"; do
    phase="$(k3s kubectl get pv "$pv" -o jsonpath='{.status.phase}' 2>/dev/null || true)"; path="$(k3s kubectl get pv "$pv" -o jsonpath='{.spec.local.path}' 2>/dev/null || true)"; node="$(k3s kubectl get pv "$pv" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' 2>/dev/null || true)"
    [[ "$phase" == Bound ]] || { bad "PV $pv phase=$phase"; continue; }
    [[ "$node" == "$TARGET_NODE" ]] || bad "PV $pv node=$node expected=$TARGET_NODE"
    [[ "$path" == "$PV_TARGET_ROOT/"* && -d "$path" ]] && ok "PV $pv bound to recovered data" || bad "PV $pv invalid/missing path: $path"
  done
  workloads=(tempo-0 kube-prometheus-stack-grafana-0 loki-0 prometheus-kube-prometheus-stack-prometheus-0)
  for pod in "${workloads[@]}"; do
    ready="$(k3s kubectl -n monitoring get pod "$pod" -o json 2>/dev/null | python3 -c 'import json,sys; p=json.load(sys.stdin); cs=p.get("status",{}).get("containerStatuses",[]); print("true" if cs and all(x.get("ready") for x in cs) else "false")' 2>/dev/null || true)"
    [[ "$ready" == true ]] && ok "persistent workload ready: $pod" || bad "persistent workload not ready: $pod"
  done
  [[ -d "$K3S_DATA_DIR/agent/images" && -n "$(find "$K3S_DATA_DIR/agent/images" -maxdepth 1 -type f -name '*.tar' -print -quit 2>/dev/null)" ]] && ok "native OCI preload present" || bad "native OCI preload missing"
fi

if [[ $fail -ne 0 ]]; then echo "DR preflight [$STAGE]: FAILED"; exit 1; fi
echo "DR preflight [$STAGE]: PASS"
