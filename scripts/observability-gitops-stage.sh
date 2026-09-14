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

# Capture the current Helm release state before and after staging. We use the
# stable tabular output rather than version-dependent JSON/template features.
capture_helm_state() {
  helm list -n "$NAMESPACE" --no-headers \
    | awk -F '\t' 'BEGIN { OFS="\t" } { print $1, $8, $5 }' \
    | sort
}

before="$(mktemp)"
after="$(mktemp)"
trap 'rm -f "$before" "$after"' EXIT

capture_helm_state > "$before"

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
  suspend="$(kubectl get helmrelease -n "$NAMESPACE" "$name" -o jsonpath='{.spec.suspend}')"
  if [[ "$suspend" != "true" ]]; then
    echo "error: HelmRelease/$name is not suspended" >&2
    exit 1
  fi
done

echo
echo "HelmRepository readiness:"
kubectl get helmrepository -n "$NAMESPACE"

capture_helm_state > "$after"

if ! diff -u "$before" "$after"; then
  echo "error: Helm release chart/version/status changed during staging" >&2
  exit 1
fi

echo
echo "Existing Helm releases were unchanged."
echo "All staged HelmRelease objects are suspended."
echo "Observability GitOps staging validation: OK"
