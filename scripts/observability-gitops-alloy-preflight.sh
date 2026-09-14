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

# Do not parse Helm columns: older/newer Helm builds differ in whitespace.
# Filter by release name and validate the raw row for status/chart instead.
runtime="$(helm list -n "$NAMESPACE" --filter "^${RELEASE}$" --no-headers)"
if [[ -z "$runtime" ]]; then
  echo "error: existing Helm release '$RELEASE' was not found in namespace '$NAMESPACE'" >&2
  exit 1
fi

if ! grep -Eq "(^|[[:space:]])alloy-${EXPECTED_CHART_VERSION//./\\.}([[:space:]]|$)" <<<"$runtime"; then
  echo "error: runtime Alloy chart differs from expected GitOps version" >&2
  echo "expected chart: alloy-$EXPECTED_CHART_VERSION" >&2
  echo "runtime row:    $runtime" >&2
  exit 1
fi

if ! grep -Eq '(^|[[:space:]])deployed([[:space:]]|$)' <<<"$runtime"; then
  echo "error: runtime Alloy release is not deployed" >&2
  echo "runtime row: $runtime" >&2
  exit 1
fi

# Cross-check Helm storage ownership independently from helm list rendering.
deployed_secret_count="$(kubectl get secret -n "$NAMESPACE" -l owner=helm,name="$RELEASE",status=deployed \
  -o name 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$deployed_secret_count" != "1" ]]; then
  echo "error: expected exactly one deployed Helm storage Secret for '$RELEASE', found $deployed_secret_count" >&2
  kubectl get secret -n "$NAMESPACE" -l owner=helm,name="$RELEASE" \
    -o custom-columns='NAME:.metadata.name,STATUS:.metadata.labels.status,VERSION:.metadata.labels.version' >&2 || true
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
[[ "$release_name" == "$RELEASE" ]] || {
  echo "error: HelmRelease/alloy releaseName=$release_name expected=$RELEASE" >&2
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

pod_count="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=alloy -o name | wc -l | tr -d ' ')"
if [[ "$pod_count" == "0" ]]; then
  echo "error: no Alloy pods found" >&2
  exit 1
fi

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
