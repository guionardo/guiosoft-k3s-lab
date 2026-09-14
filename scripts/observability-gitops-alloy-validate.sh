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

for cmd in flux kubectl helm grep; do
  need "$cmd"
done

echo "Alloy Flux adoption validation"
echo

echo "Reconciling Git source and observability manifests..."
flux reconcile source git flux-system
flux reconcile kustomization flux-system
flux reconcile kustomization observability-helm

echo
echo "Reconciling HelmRelease/alloy..."
flux reconcile helmrelease alloy -n "$NAMESPACE" --with-source

echo
suspend="$(kubectl get helmrelease -n "$NAMESPACE" "$RELEASE" -o jsonpath='{.spec.suspend}')"
ready="$(kubectl get helmrelease -n "$NAMESPACE" "$RELEASE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
release_name="$(kubectl get helmrelease -n "$NAMESPACE" "$RELEASE" -o jsonpath='{.spec.releaseName}')"
target_namespace="$(kubectl get helmrelease -n "$NAMESPACE" "$RELEASE" -o jsonpath='{.spec.targetNamespace}')"
storage_namespace="$(kubectl get helmrelease -n "$NAMESPACE" "$RELEASE" -o jsonpath='{.spec.storageNamespace}')"
version="$(kubectl get helmrelease -n "$NAMESPACE" "$RELEASE" -o jsonpath='{.spec.chart.spec.version}')"

[[ "$suspend" != "true" ]] || { echo "error: HelmRelease/alloy is still suspended" >&2; exit 1; }
[[ "$ready" == "True" ]] || {
  echo "error: HelmRelease/alloy is not Ready" >&2
  kubectl describe helmrelease -n "$NAMESPACE" "$RELEASE" >&2 || true
  exit 1
}
[[ "$release_name" == "$RELEASE" ]] || { echo "error: unexpected releaseName=$release_name" >&2; exit 1; }
[[ "$target_namespace" == "$NAMESPACE" ]] || { echo "error: unexpected targetNamespace=$target_namespace" >&2; exit 1; }
[[ "$storage_namespace" == "$NAMESPACE" ]] || { echo "error: unexpected storageNamespace=$storage_namespace" >&2; exit 1; }
[[ "$version" == "$EXPECTED_CHART_VERSION" ]] || { echo "error: unexpected chart version=$version" >&2; exit 1; }

runtime="$(helm list -n "$NAMESPACE" --filter '^alloy$' --no-headers || true)"
[[ -n "$runtime" ]] || { echo "error: runtime Helm release alloy not found" >&2; exit 1; }
grep -Eq 'alloy-1\.12\.1' <<<"$runtime" || { echo "error: runtime chart is not alloy-$EXPECTED_CHART_VERSION" >&2; printf '%s\n' "$runtime" >&2; exit 1; }
grep -Eq '(^|[[:space:]])deployed([[:space:]]|$)' <<<"$runtime" || { echo "error: runtime Helm release is not deployed" >&2; printf '%s\n' "$runtime" >&2; exit 1; }

helm_secret="$(kubectl get secret -n "$NAMESPACE" -l owner=helm,name="$RELEASE",status=deployed -o name)"
[[ -n "$helm_secret" ]] || { echo "error: deployed Helm storage Secret for alloy not found" >&2; exit 1; }

pod_count="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=alloy -o name | wc -l | tr -d ' ')"
[[ "$pod_count" -ge 1 ]] || { echo "error: no Alloy pods found" >&2; exit 1; }

not_ready="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=alloy \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
  | awk '$2 != "Running" || $3 != "True" { print $1 }')"
[[ -z "$not_ready" ]] || {
  echo "error: one or more Alloy pods are not Running/Ready:" >&2
  printf '%s\n' "$not_ready" >&2
  exit 1
}

for name in kube-prometheus-stack loki otel-collector tempo; do
  other_suspend="$(kubectl get helmrelease -n "$NAMESPACE" "$name" -o jsonpath='{.spec.suspend}')"
  [[ "$other_suspend" == "true" ]] || {
    echo "error: HelmRelease/$name must remain suspended during Alloy adoption" >&2
    exit 1
  }
done

echo "HelmRelease/alloy: Ready"
printf 'Runtime release: %s\n' "$runtime"
echo "Alloy Pods: Running/Ready"
echo "Other observability HelmReleases remain suspended."
echo "Alloy Flux adoption validation: OK"
