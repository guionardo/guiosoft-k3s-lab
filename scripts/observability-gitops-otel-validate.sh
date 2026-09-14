#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
RELEASE="otel-collector"
EXPECTED_CHART="opentelemetry-collector-0.172.1"

need() {
  command -v "$1" >/dev/null || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in flux kubectl helm grep awk; do
  need "$cmd"
done

echo "OpenTelemetry Collector Flux adoption validation"
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

runtime="$(helm list -n "$NAMESPACE" --filter '^otel-collector$' --no-headers)"
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
echo "Collector workload:"
kubectl get deployment,pod,service -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" -o wide

not_ready="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
  | awk '$2 != "Running" || $3 != "True" { print $1 }')"

if [[ -n "$not_ready" ]]; then
  echo "error: one or more OpenTelemetry Collector pods are not Running/Ready:" >&2
  printf '%s\n' "$not_ready" >&2
  exit 1
fi

# Discover the Service by Helm release label; the chart-generated Service name
# is not necessarily identical to the Helm release name.
service_names="$(kubectl get service -n "$NAMESPACE" \
  -l app.kubernetes.io/instance="$RELEASE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"

[[ -n "$service_names" ]] || {
  echo "error: no Service found for Helm release '$RELEASE'" >&2
  exit 1
}

service_ok=""
while IFS= read -r service_name; do
  [[ -n "$service_name" ]] || continue
  svc_ports="$(kubectl get service -n "$NAMESPACE" "$service_name" \
    -o jsonpath='{range .spec.ports[*]}{.port}{"\n"}{end}')"

  if grep -qx '4317' <<<"$svc_ports" && grep -qx '4318' <<<"$svc_ports"; then
    service_ok="$service_name"
    break
  fi
done <<<"$service_names"

if [[ -z "$service_ok" ]]; then
  echo "error: no Service for release '$RELEASE' exposes both OTLP ports 4317 and 4318" >&2
  kubectl get service -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE" -o wide >&2 || true
  exit 1
fi

for name in kube-prometheus-stack tempo loki; do
  other_suspend="$(kubectl get helmrelease -n "$NAMESPACE" "$name" -o jsonpath='{.spec.suspend}')"
  [[ "$other_suspend" == "true" ]] || {
    echo "error: HelmRelease/$name should still be suspended" >&2
    exit 1
  }
done

alloy_suspend="$(kubectl get helmrelease -n "$NAMESPACE" alloy -o jsonpath='{.spec.suspend}')"
[[ "$alloy_suspend" == "false" ]] || {
  echo "error: HelmRelease/alloy unexpectedly became suspended" >&2
  exit 1
}

echo
echo "HelmRelease/otel-collector: Ready"
echo "OpenTelemetry Collector Pods: Running/Ready"
echo "OTLP service ports 4317/4318: OK ($service_ok)"
echo "Tempo, Loki and kube-prometheus-stack remain suspended."
echo "OpenTelemetry Collector Flux adoption validation: OK"
