#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"

need() {
  command -v "$1" >/dev/null || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in flux kubectl helm diff; do
  need "$cmd"
done

echo "Observability GitOps staging reconciliation"
echo

# Capture the current Helm release chart/version state before Flux creates the
# suspended HelmRelease objects. Go templates avoid shell/Python quoting issues.
before="$(mktemp)"
after="$(mktemp)"
trap 'rm -f "$before" "$after"' EXIT

helm list -n "$NAMESPACE" \
  -o template \
  --template '{{range .}}{{.Name}}{{"\t"}}{{.Chart}}{{"\t"}}{{.Status}}{{"\n"}}{{end}}' \
  | sort > "$before"

echo "Current Helm releases:"
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

helm list -n "$NAMESPACE" \
  -o template \
  --template '{{range .}}{{.Name}}{{"\t"}}{{.Chart}}{{"\t"}}{{.Status}}{{"\n"}}{{end}}' \
  | sort > "$after"

if ! diff -u "$before" "$after"; then
  echo "error: Helm release chart/version/status changed during staging" >&2
  exit 1
fi

echo
echo "Existing Helm releases were unchanged."
echo "All staged HelmRelease objects are suspended."
echo "Observability GitOps staging validation: OK"
