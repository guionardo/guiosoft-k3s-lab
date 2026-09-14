#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
RELEASE="alloy"
EXPECTED_CHART_VERSION="${ALLOY_CHART_VERSION:-1.12.1}"

need() {
  command -v "$1" >/dev/null || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in flux kubectl helm awk grep sort; do
  need "$cmd"
done

echo "Alloy Flux adoption preflight"
echo

# Require the staging layer to exist and still be suspended before any adoption.
if ! flux get kustomization observability-helm | grep -Eq 'True'; then
  echo "error: Flux Kustomization 'observability-helm' is not Ready" >&2
  flux get kustomization observability-helm || true
  exit 1
fi

for name in alloy kube-prometheus-stack loki otel-collector tempo; do
  if ! kubectl get helmrelease -n "$NAMESPACE" "$name" >/dev/null 2>&1; then
    echo "error: HelmRelease/$name is missing" >&2
    exit 1
  fi

  suspend="$(kubectl get helmrelease -n "$NAMESPACE" "$name" -o jsonpath='{.spec.suspend}')"
  if [[ "$suspend" != "true" ]]; then
    echo "error: HelmRelease/$name is not suspended; refusing adoption preflight" >&2
    exit 1
  fi
done

repo_ready="$(kubectl get helmrepository -n "$NAMESPACE" grafana -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
if [[ "$repo_ready" != "True" ]]; then
  echo "error: HelmRepository/grafana is not Ready" >&2
  kubectl get helmrepository -n "$NAMESPACE" grafana -o wide >&2 || true
  exit 1
fi

runtime="$(helm list -n "$NAMESPACE" --no-headers | awk -F '\t' '$1 == "alloy" { print $1 "\t" $6 "\t" $5 }')"
if [[ -z "$runtime" ]]; then
  echo "error: existing Helm release 'alloy' was not found in namespace '$NAMESPACE'" >&2
  echo >&2
  echo "Helm releases containing 'alloy' in any namespace:" >&2
  global_matches="$(helm list -A --no-headers | awk -F '\t' 'tolower($1) ~ /alloy/ { print }')"
  if [[ -n "$global_matches" ]]; then
    printf '%s\n' "$global_matches" >&2
  else
    echo "  (none)" >&2
  fi

  echo >&2
  echo "Helm storage Secrets for release name 'alloy':" >&2
  secret_matches="$(kubectl get secret -A -l owner=helm,name="$RELEASE" \
    -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.metadata.labels.status,VERSION:.metadata.labels.version' \
    --no-headers 2>/dev/null || true)"
  if [[ -n "$secret_matches" ]]; then
    printf '%s\n' "$secret_matches" >&2
  else
    echo "  (none)" >&2
  fi

  echo >&2
  echo "Kubernetes workloads/resources containing 'alloy' in monitoring:" >&2
  kubectl get deployment,statefulset,daemonset,pod,service -n "$NAMESPACE" \
    -o name 2>/dev/null | grep -i alloy >&2 || echo "  (none)" >&2

  echo >&2
  echo "Refusing adoption: Flux must not create a fresh release until the existing runtime ownership is understood." >&2
  exit 1
fi

runtime_chart="$(awk -F '\t' '{print $2}' <<<"$runtime")"
runtime_status="$(awk -F '\t' '{print $3}' <<<"$runtime")"

if [[ "$runtime_chart" != "alloy-$EXPECTED_CHART_VERSION" ]]; then
  echo "error: runtime Alloy chart differs from expected GitOps version" >&2
  echo "expected: alloy-$EXPECTED_CHART_VERSION" >&2
  echo "actual:   $runtime_chart" >&2
  exit 1
fi

if [[ "$runtime_status" != "deployed" ]]; then
  echo "error: runtime Alloy release is not deployed: $runtime_status" >&2
  exit 1
fi

desired_version="$(kubectl get helmrelease -n "$NAMESPACE" alloy -o jsonpath='{.spec.chart.spec.version}')"
release_name="$(kubectl get helmrelease -n "$NAMESPACE" alloy -o jsonpath='{.spec.releaseName}')"
target_namespace="$(kubectl get helmrelease -n "$NAMESPACE" alloy -o jsonpath='{.spec.targetNamespace}')"
storage_namespace="$(kubectl get helmrelease -n "$NAMESPACE" alloy -o jsonpath='{.spec.storageNamespace}')"

[[ "$desired_version" == "$EXPECTED_CHART_VERSION" ]] || {
  echo "error: HelmRelease/alloy version=$desired_version expected=$EXPECTED_CHART_VERSION" >&2
  exit 1
}
[[ "$release_name" == "alloy" ]] || {
  echo "error: HelmRelease/alloy releaseName=$release_name expected=alloy" >&2
  exit 1
}
[[ "$target_namespace" == "$NAMESPACE" ]] || {
  echo "error: HelmRelease/alloy targetNamespace=$target_namespace expected=$NAMESPACE" >&2
  exit 1
}
[[ "$storage_namespace" == "$NAMESPACE" ]] || {
  echo "error: HelmRelease/alloy storageNamespace=$storage_namespace expected=$NAMESPACE" >&2
  exit 1
}

echo "Runtime Helm release:"
printf '%s\n' "$runtime"
echo

echo "Alloy pods:"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=alloy -o wide

not_ready="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=alloy \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
  | awk '$2 != "Running" || $3 != "True" { print $1 }')"

if [[ -n "$not_ready" ]]; then
  echo "error: one or more Alloy pods are not Running/Ready:" >&2
  printf '%s\n' "$not_ready" >&2
  exit 1
fi

echo
echo "Preflight result: OK"
echo "Alloy is ready for declarative adoption by changing only spec.suspend from true to false."
echo "No cluster resources were changed by this preflight."
