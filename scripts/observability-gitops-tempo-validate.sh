#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
RELEASE="tempo"
EXPECTED_CHART="tempo-2.2.3"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

need() {
  command -v "$1" >/dev/null || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in flux kubectl helm grep; do
  need "$cmd"
done

echo "Tempo Flux adoption validation"
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

runtime="$(helm list -n "$NAMESPACE" --filter '^tempo$' --no-headers)"
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
echo "Tempo workload:"
kubectl get statefulset,deployment,pod,service,pvc -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" -o wide 2>/dev/null || \
  kubectl get statefulset,deployment,pod,service,pvc -n "$NAMESPACE" -o wide | grep -i tempo || true

pods="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=tempo -o name 2>/dev/null || true)"
if [[ -z "$pods" ]]; then
  pods="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" -o name 2>/dev/null || true)"
fi
[[ -n "$pods" ]] || {
  echo "error: Tempo pod not found" >&2
  exit 1
}

not_ready="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=tempo \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null \
  | awk '$2 != "Running" || $3 != "True" { print $1 }')"
if [[ -n "$not_ready" ]]; then
  echo "error: one or more Tempo pods are not Running/Ready:" >&2
  printf '%s\n' "$not_ready" >&2
  exit 1
fi

# Tempo stores traces persistently in the homelab configuration; ensure its PVC stayed Bound.
pvc_state="$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{range .items[?(@.metadata.name=="storage-tempo-0")]}{.status.phase}{end}' 2>/dev/null || true)"
if [[ -n "$pvc_state" && "$pvc_state" != "Bound" ]]; then
  echo "error: Tempo PVC is not Bound: $pvc_state" >&2
  exit 1
fi

# Existing integration test exercises app -> OTel Collector -> Tempo -> trace lookup.
if [[ -x "$REPO_ROOT/scripts/otel-go-demo.sh" ]]; then
  echo
  echo "Running distributed trace validation through OTel Collector -> Tempo..."
  "$REPO_ROOT/scripts/otel-go-demo.sh" test
else
  echo "error: scripts/otel-go-demo.sh is not executable or missing" >&2
  exit 1
fi

for name in kube-prometheus-stack loki; do
  other_suspend="$(kubectl get helmrelease -n "$NAMESPACE" "$name" -o jsonpath='{.spec.suspend}')"
  [[ "$other_suspend" == "true" ]] || {
    echo "error: HelmRelease/$name should still be suspended" >&2
    exit 1
  }
done

for name in alloy otel-collector; do
  adopted_suspend="$(kubectl get helmrelease -n "$NAMESPACE" "$name" -o jsonpath='{.spec.suspend}')"
  [[ "$adopted_suspend" == "false" ]] || {
    echo "error: HelmRelease/$name unexpectedly became suspended" >&2
    exit 1
  }
done

echo
echo "HelmRelease/tempo: Ready"
echo "Tempo Pods: Running/Ready"
echo "Distributed trace path via OpenTelemetry Collector -> Tempo: OK"
echo "Loki and kube-prometheus-stack remain suspended."
echo "Tempo Flux adoption validation: OK"
