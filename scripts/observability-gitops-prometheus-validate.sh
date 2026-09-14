#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
RELEASE="kube-prometheus-stack"
EXPECTED_CHART="kube-prometheus-stack-89.2.0"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

need() {
  command -v "$1" >/dev/null || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in flux kubectl helm grep awk make; do
  need "$cmd"
done

echo "kube-prometheus-stack Flux adoption validation"
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

runtime="$(helm list -n "$NAMESPACE" --filter '^kube-prometheus-stack$' --no-headers)"
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
echo "Monitoring workloads:"
kubectl get pod -n "$NAMESPACE" -o wide

bad_pods="$(kubectl get pods -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.containerStatuses[*]}{.ready}{","}{end}{"\n"}{end}' \
  | awk '$2 != "Running" { print $1 }')"
if [[ -n "$bad_pods" ]]; then
  echo "error: one or more monitoring pods are not Running:" >&2
  printf '%s\n' "$bad_pods" >&2
  exit 1
fi

# Persistent volumes for Prometheus/Grafana/Tempo must remain bound.
echo
echo "Monitoring PVCs:"
kubectl get pvc -n "$NAMESPACE" -o wide
unbound="$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' | awk '$2 != "Bound" {print $1}')"
if [[ -n "$unbound" ]]; then
  echo "error: one or more monitoring PVCs are not Bound:" >&2
  printf '%s\n' "$unbound" >&2
  exit 1
fi

# Prometheus Operator CRDs must still exist after adoption.
for crd in prometheuses.monitoring.coreos.com alertmanagers.monitoring.coreos.com servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com; do
  kubectl get crd "$crd" >/dev/null || {
    echo "error: required CRD missing: $crd" >&2
    exit 1
  }
done

# All observability releases should now be adopted by Flux.
for name in alloy otel-collector tempo loki kube-prometheus-stack; do
  current_suspend="$(kubectl get helmrelease -n "$NAMESPACE" "$name" -o jsonpath='{.spec.suspend}')"
  [[ "$current_suspend" == "false" ]] || {
    echo "error: HelmRelease/$name is unexpectedly suspended" >&2
    exit 1
  }
done

echo
echo "Running existing observability validation suite..."
(
  cd "$REPO_ROOT"
  make observability-validate
)

echo
echo "kube-prometheus-stack HelmRelease: Ready"
echo "Prometheus Operator CRDs: present"
echo "Monitoring Pods: Running"
echo "Monitoring PVCs: Bound"
echo "All observability HelmReleases are Flux-managed."
echo "Existing observability validation suite: OK"
echo "kube-prometheus-stack Flux adoption validation: OK"
