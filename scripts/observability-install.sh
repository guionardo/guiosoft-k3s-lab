#!/usr/bin/env bash
set -euo pipefail

CHART_VERSION="${KUBE_PROMETHEUS_STACK_VERSION:-89.2.0}"
RELEASE="${OBSERVABILITY_RELEASE:-kube-prometheus-stack}"
NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
VALUES="${OBSERVABILITY_VALUES:-kubernetes/observability/kube-prometheus-stack-values.yaml}"

command -v kubectl >/dev/null || { echo "error: kubectl not found" >&2; exit 1; }
command -v helm >/dev/null || { echo "error: helm not found; run make tools first" >&2; exit 1; }
[[ -f "$VALUES" ]] || { echo "error: values file not found: $VALUES" >&2; exit 1; }

kubectl apply -f kubernetes/namespaces/monitoring.yaml

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update prometheus-community

helm upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --version "$CHART_VERSION" \
  --values "$VALUES" \
  --wait \
  --timeout 10m

printf '\nObservability baseline installed.\n'
echo "Release: $RELEASE"
echo "Namespace: $NAMESPACE"
echo "Chart: kube-prometheus-stack $CHART_VERSION"
echo "Grafana remains private; use make observability-grafana for local access."
