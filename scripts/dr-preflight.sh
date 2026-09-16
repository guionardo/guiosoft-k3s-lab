#!/usr/bin/env bash
set -uo pipefail

MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"
ISOLATION_TABLE="${DR_ISOLATION_TABLE:-dr_isolation}"
PROD_HOSTNAME="${DR_PRODUCTION_HOSTNAME:-guiosoft-info}"
PROD_IP="${DR_PRODUCTION_IP:-192.168.88.9}"
K3S_DATA_DIR="${K3S_DATA_DIR:-/var/lib/rancher/k3s}"
fail=0

ok() { printf 'OK    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
info() { printf 'INFO  %s\n' "$*"; }

host="$(hostname -s)"
[[ "$host" != "$PROD_HOSTNAME" ]] && ok "hostname guard: $host" || bad "production hostname detected"
if ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PROD_IP"; then
  bad "production IP $PROD_IP detected"
else
  ok "production IP guard"
fi
[[ -s "$MARKER_FILE" ]] && grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" && ok "DR target marker" || bad "DR target marker"
command -v nft >/dev/null && nft list table inet "$ISOLATION_TABLE" >/dev/null 2>&1 && ok "WAN isolation inet/$ISOLATION_TABLE" || bad "WAN isolation"
command -v k3s >/dev/null && ok "K3s installed" || bad "K3s installed"
command -v restic >/dev/null && ok "Restic installed" || info "Restic not installed (required for direct R2 operations)"
command -v sops >/dev/null && ok "SOPS installed" || info "SOPS not installed"
command -v age >/dev/null && ok "age installed" || info "age not installed"
[[ -d "$K3S_DATA_DIR" ]] && ok "K3s data dir: $K3S_DATA_DIR" || bad "K3s data dir missing: $K3S_DATA_DIR"
[[ -d "$K3S_DATA_DIR/agent/images" ]] && ok "K3s native OCI preload directory" || info "OCI preload directory not created yet"

if command -v k3s >/dev/null && systemctl is-active --quiet k3s 2>/dev/null; then
  if k3s kubectl get --raw=/readyz >/dev/null 2>&1; then ok "K3s API ready"; else bad "K3s service active but API not ready"; fi
  info "nodes:"
  k3s kubectl get nodes -o wide 2>/dev/null || true
  info "Flux suspension:"
  k3s kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SUSPEND:.spec.suspend' 2>/dev/null || true
  info "cloudflared replicas:"
  k3s kubectl -n cloudflare get deploy cloudflared -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas' 2>/dev/null || true
else
  info "K3s service is not active"
fi

if [[ $fail -ne 0 ]]; then
  echo "DR preflight: FAILED"
  exit 1
fi
echo "DR preflight: PASS"
