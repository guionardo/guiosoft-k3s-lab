#!/usr/bin/env bash
set -euo pipefail

MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"
ISOLATION_TABLE="${DR_ISOLATION_TABLE:-dr_isolation}"
CONFIRM_EXPECTED="neutralize-isolated-cluster"

fail(){ echo "error: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "run as root"
[[ "${DR_NEUTRALIZE_CONFIRM:-}" == "$CONFIRM_EXPECTED" ]] || fail "set DR_NEUTRALIZE_CONFIRM=$CONFIRM_EXPECTED"
[[ -s "$MARKER_FILE" ]] && grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" || fail "valid DR target marker missing"
nft list table inet "$ISOLATION_TABLE" >/dev/null 2>&1 || fail "DR WAN isolation is not active"
command -v k3s >/dev/null || fail "k3s not found"
k3s kubectl get --raw=/readyz >/dev/null 2>&1 || fail "K3s API is not ready"
K="k3s kubectl"

suspend_kind(){
  local resource="$1" items
  items="$($K get "$resource" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  [[ -z "$items" ]] && return 0
  while read -r ns name; do [[ -z "$name" ]] || $K -n "$ns" patch "$resource" "$name" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null; done <<<"$items"
}
scale_deployments(){
  local ns="$1" selector="${2:-}" args=(-n "$ns" get deploy)
  [[ -z "$selector" ]] || args+=(-l "$selector")
  local items; items="$($K "${args[@]}" -o name 2>/dev/null || true)"
  [[ -z "$items" ]] || while read -r item; do [[ -z "$item" ]] || $K -n "$ns" scale "$item" --replicas=0 >/dev/null; done <<<"$items"
}
scale_statefulsets(){
  local ns="$1" items; items="$($K -n "$ns" get sts -o name 2>/dev/null || true)"
  [[ -z "$items" ]] || while read -r item; do [[ -z "$item" ]] || $K -n "$ns" scale "$item" --replicas=0 >/dev/null; done <<<"$items"
}

# Stop reconcilers before changing restored desired state.
suspend_kind kustomizations.kustomize.toolkit.fluxcd.io
suspend_kind helmreleases.helm.toolkit.fluxcd.io
suspend_kind gitrepositories.source.toolkit.fluxcd.io

# Never let the recovered cluster attach to the production Cloudflare tunnel.
scale_deployments cloudflare
# Application writers/services are deliberately inert until explicitly selected
# for validation.
scale_deployments firecrawl
scale_deployments lab
scale_deployments monitoring
scale_statefulsets monitoring

# DaemonSets cannot be scaled. Add an impossible DR-neutralized nodeSelector to
# monitoring DSs (node-exporter, Loki canary, etc.). The original selector is
# captured as an annotation so a future helper can restore it deliberately.
for ds in $($K -n monitoring get ds -o name 2>/dev/null || true); do
  current="$($K -n monitoring get "$ds" -o jsonpath='{.spec.template.spec.nodeSelector}' 2>/dev/null || true)"
  $K -n monitoring annotate "$ds" "guiosoft.info/dr-original-node-selector=$current" --overwrite >/dev/null
  $K -n monitoring patch "$ds" --type=merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"guiosoft.info/dr-neutralized":"true"}}}}}' >/dev/null
done

# Flux controllers themselves may remain scheduled; all sources and reconcilers
# are suspended and WAN is rejected independently by nftables.
echo "Restored cluster neutralized."
echo "Flux sources/Kustomizations/HelmReleases: suspended"
echo "cloudflare/firecrawl/lab/monitoring Deployments: replicas=0"
echo "monitoring StatefulSets: replicas=0"
echo "monitoring DaemonSets: unschedulable via DR nodeSelector"
