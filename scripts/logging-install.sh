#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-18.5.0}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.12.1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v helm >/dev/null || { echo "error: helm not found; run make tools first" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "error: kubectl not found" >&2; exit 1; }

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
helm repo update >/dev/null

echo "Installing Loki community chart $LOKI_CHART_VERSION..."
helm upgrade --install loki grafana-community/loki \
  --namespace "$NAMESPACE" \
  --version "$LOKI_CHART_VERSION" \
  --values "$REPO_ROOT/kubernetes/observability/loki-values.yaml" \
  --wait \
  --timeout 8m

echo "Installing Grafana Alloy chart $ALLOY_CHART_VERSION..."
helm upgrade --install alloy grafana/alloy \
  --namespace "$NAMESPACE" \
  --version "$ALLOY_CHART_VERSION" \
  --values "$REPO_ROOT/kubernetes/observability/alloy-values.yaml" \
  --wait \
  --timeout 5m

echo
printf 'Logging foundation installed.\n'
printf 'Loki gateway inside cluster: http://loki-gateway.%s.svc.cluster.local\n' "$NAMESPACE"
printf 'Alloy collects Pod logs through the Kubernetes API and forwards them to Loki.\n'
