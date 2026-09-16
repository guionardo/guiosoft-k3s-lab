#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
RELEASE="loki"
EXPECTED_CHART="loki-18.5.0"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

need() {
  command -v "$1" >/dev/null || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in flux kubectl helm grep awk bash; do
  need "$cmd"
done

echo "Loki Flux adoption validation"
echo

flux reconcile source git flux-system
flux reconcile kustomization observability-helm
flux reconcile helmrelease "$RELEASE" -n "$NAMESPACE"

echo

echo "HelmRelease status:"
kubectl get helmrelease -n "$NAMESPACE" "$RELEASE" \
  -o custom-columns='NAME:.metadata.name,SUSPEND:.spec.suspend,READY:.status.conditions[?(@.type=="Ready")].status,REVISION:.status.history[0].chartVersion' \
  --no-headers

suspend="$(kubectl get helmrelease -n "$NAMESPACE" "$RELEASE" -o jsonpath='{.spec.suspend}')"
ready="$(kubectl get helmrelease -n "$NAMESPACE" "$RELEASE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"

[[ "$suspend" == "false" ]] || {
  echo "error: HelmRelease/$RELEASE is still suspended" >&2
  exit 1
}
[[ "$ready" == "True" ]] || {
  echo "error: HelmRelease/$RELEASE is not Ready" >&2
  kubectl describe helmrelease -n "$NAMESPACE" "$RELEASE" >&2 || true
  exit 1
}

runtime="$(helm list -n "$NAMESPACE" --filter '^loki$' --no-headers)"
[[ -n "$runtime" ]] || {
  echo "error: runtime Helm release '$RELEASE' not found" >&2
  exit 1
}

echo
echo "Runtime Helm release:"
printf '%s\n' "$runtime"

if ! grep -Fq "$EXPECTED_CHART" <<<"$runtime"; then
  echo "error: runtime chart is not $EXPECTED_CHART" >&2
  exit 1
fi
if ! grep -Eq '(^|[[:space:]])deployed([[:space:]]|$)' <<<"$runtime"; then
  echo "error: runtime Helm release is not deployed" >&2
  exit 1
fi

echo
echo "Loki workload:"
kubectl get deployment,statefulset,daemonset,pod,service,pvc -n "$NAMESPACE" \
  -l app.kubernetes.io/instance="$RELEASE" -o wide 2>/dev/null || true

pods="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" -o name 2>/dev/null || true)"
[[ -n "$pods" ]] || {
  echo "error: Loki pods not found" >&2
  exit 1
}

not_ready="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null \
  | awk '$2 != "Running" || $3 != "True" { print $1 }')"
if [[ -n "$not_ready" ]]; then
  echo "error: one or more Loki pods are not Running/Ready:" >&2
  printf '%s\n' "$not_ready" >&2
  exit 1
fi

kubectl get service -n "$NAMESPACE" loki-gateway >/dev/null 2>&1 || {
  echo "error: service/loki-gateway not found" >&2
  exit 1
}

if [[ -f "$REPO_ROOT/scripts/logging-validate.sh" ]]; then
  echo
  echo "Running end-to-end log correlation validation through Alloy -> Loki..."
  bash "$REPO_ROOT/scripts/logging-validate.sh"
else
  echo "error: scripts/logging-validate.sh is missing" >&2
  exit 1
fi

prom_suspend="$(kubectl get helmrelease -n "$NAMESPACE" kube-prometheus-stack -o jsonpath='{.spec.suspend}')"
[[ "$prom_suspend" == "true" ]] || {
  echo "error: HelmRelease/kube-prometheus-stack should still be suspended" >&2
  exit 1
}

for name in alloy otel-collector tempo; do
  adopted_suspend="$(kubectl get helmrelease -n "$NAMESPACE" "$name" -o jsonpath='{.spec.suspend}')"
  [[ "$adopted_suspend" == "false" ]] || {
    echo "error: HelmRelease/$name unexpectedly became suspended" >&2
    exit 1
  }
done

echo
echo "HelmRelease/loki: Ready"
echo "Loki Pods: Running/Ready"
echo "Alloy -> Loki log ingestion and trace_id lookup: OK"
echo "kube-prometheus-stack remains suspended."
echo "Loki Flux adoption validation: OK"
