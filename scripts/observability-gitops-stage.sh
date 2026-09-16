#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"

need() {
  command -v "$1" >/dev/null || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in flux kubectl helm awk sort; do
  need "$cmd"
done

echo "Observability GitOps ownership validation"
echo

echo "Reconciling Flux source/root and observability Kustomizations..."
flux reconcile source git flux-system
flux reconcile kustomization flux-system
flux reconcile kustomization monitoring-namespace
flux reconcile kustomization observability-helm

echo

echo "Observability HelmRelease objects:"
kubectl get helmrelease -n "$NAMESPACE" \
  -o custom-columns='NAME:.metadata.name,SUSPEND:.spec.suspend,READY:.status.conditions[?(@.type=="Ready")].status,RELEASE:.spec.releaseName,VERSION:.spec.chart.spec.version' \
  --no-headers | sort

expected=(alloy kube-prometheus-stack loki otel-collector tempo)
for name in "${expected[@]}"; do
  if ! kubectl get helmrelease -n "$NAMESPACE" "$name" >/dev/null 2>&1; then
    echo "error: expected HelmRelease/$name was not found" >&2
    exit 1
  fi

  suspend="$(kubectl get helmrelease -n "$NAMESPACE" "$name" -o jsonpath='{.spec.suspend}')"
  if [[ "$suspend" != "false" ]]; then
    echo "error: HelmRelease/$name is unexpectedly suspended" >&2
    exit 1
  fi

  ready="$(kubectl get helmrelease -n "$NAMESPACE" "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  if [[ "$ready" != "True" ]]; then
    echo "error: HelmRelease/$name is not Ready" >&2
    kubectl describe helmrelease -n "$NAMESPACE" "$name" >&2 || true
    exit 1
  fi

  runtime="$(helm list -n "$NAMESPACE" --filter "^${name}$" --no-headers)"
  if [[ -z "$runtime" ]]; then
    echo "error: runtime Helm release '$name' was not found" >&2
    exit 1
  fi

  if ! grep -Eq '(^|[[:space:]])deployed([[:space:]]|$)' <<<"$runtime"; then
    echo "error: runtime Helm release '$name' is not deployed" >&2
    printf '%s\n' "$runtime" >&2
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

echo
echo "All observability HelmRelease objects are active and Ready."
echo "All runtime Helm releases are deployed."
echo "All HelmRepository objects are Ready."
echo "Observability GitOps ownership validation: OK"
