#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
TEMPO_CHART_VERSION="${TEMPO_CHART_VERSION:-2.2.3}"
OTEL_COLLECTOR_CHART_VERSION="${OTEL_COLLECTOR_CHART_VERSION:-0.172.1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v helm >/dev/null || { echo "error: helm not found; run make tools first" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "error: kubectl not found" >&2; exit 1; }

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update >/dev/null
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update >/dev/null
helm repo update >/dev/null

echo "Installing Tempo chart $TEMPO_CHART_VERSION..."
helm upgrade --install tempo grafana-community/tempo \
  --namespace "$NAMESPACE" \
  --version "$TEMPO_CHART_VERSION" \
  --values "$REPO_ROOT/kubernetes/observability/tempo-values.yaml" \
  --wait \
  --timeout 5m

echo "Installing OpenTelemetry Collector chart $OTEL_COLLECTOR_CHART_VERSION..."
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --namespace "$NAMESPACE" \
  --version "$OTEL_COLLECTOR_CHART_VERSION" \
  --values "$REPO_ROOT/kubernetes/observability/opentelemetry-collector-values.yaml" \
  --wait \
  --timeout 5m

echo
printf 'Tracing foundation installed.\n'
printf 'OTLP gRPC endpoint inside cluster: otel-collector-opentelemetry-collector.%s.svc.cluster.local:4317\n' "$NAMESPACE"
printf 'OTLP HTTP endpoint inside cluster: http://otel-collector-opentelemetry-collector.%s.svc.cluster.local:4318\n' "$NAMESPACE"
printf 'Tempo query endpoint inside cluster: http://tempo.%s.svc.cluster.local:3200\n' "$NAMESPACE"
