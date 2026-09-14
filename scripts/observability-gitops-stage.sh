#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"

need() {
  command -v "$1" >/dev/null || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in flux kubectl helm diff awk sort; do
  need "$cmd"
done

echo "Observability GitOps staging reconciliation"
echo

# Capture the current Helm release state before and after staging. The default
# Helm table is tab-separated; fields are NAME, NAMESPACE, REVISION, UPDATED,
# STATUS, CHART and APP VERSION. We compare NAME + CHART + STATUS.
capture_helm_state() {
  helm list -n "$NAMESPACE" --no-headers \
    | awk -F '\t' 'BEGIN { OFS="\t" } { print $1, $6, $5 }' \
    | sort
}

before="$(mktemp)"
after="$(mktemp)"
trap 'rm -f "$before" "$after"' EXIT

capture_helm_state > "$before"

if [[ ! -s "$before" ]]; then
  echo "error: no Helm releases found in namespace '$NAMESPACE'" >&2
  exit 1
fi

echo "Current Helm releases (name, chart, status):"
cat "$before"
echo

echo "Reconciling Flux source/root and staging Kustomizations..."
flux reconcile source git flux-system
flux reconcile kustomization flux-system
flux reconcile kustomization monitoring-namespace
flux reconcile kustomization observability-helm

echo

echo "Staged HelmRelease objects:"
kubectl get helmrelease -n "$NAMESPACE" \
  -o custom-columns='NAME:.metadata.name,SUSPEND:.spec.suspend,RELEASE:.spec.releaseName,VERSION:.spec.chart.spec.version' \
  --no-headers | sort

expected=(alloy kube-prometheus-stack loki otel-collector tempo)
for name in "${expected[@]}"; do
  if ! kubectl get helmrelease -n "$NAMESPACE" "$name" >/dev/null 2>&1; then
    echo "error: expected HelmRelease/$name was not staged" >&2
    exit 1
  fi

  suspend="$(kubectl get helmrelease -n "$NAMESPACE" "$name" -o jsonpath='{.spec.suspend}')"
  if [[ "$suspend" != "true" ]]; then
    echo "error: HelmRelease/$name is not suspended" >&2
    exit 1
  fi
done

echo
echo "HelmRepository readiness:"
kubectl get helmrepository -n "$NAMESPACE"

not_ready="$(kubectl get helmrepository -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
  | awk '$2 != "True" { print $1 }')"
if [[ -n "$not_ready" ]]; then
  echo "error: one or more HelmRepository objects are not Ready:" >&2
  printf '%s\n' "$not_ready" >&2
  exit 1
fi

capture_helm_state > "$after"

if ! diff -u "$before" "$after"; then
  echo "error: Helm release chart/version/status changed during staging" >&2
  exit 1
fi

echo
echo "Existing Helm releases were unchanged."
echo "All staged HelmRelease objects are suspended."
echo "All HelmRepository objects are Ready."
echo "Observability GitOps staging validation: OK"
