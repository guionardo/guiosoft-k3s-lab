#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
RELEASE="${OBSERVABILITY_RELEASE:-kube-prometheus-stack}"
PROM_SERVICE="${OBSERVABILITY_PROM_SERVICE:-kube-prometheus-stack-prometheus}"

command -v kubectl >/dev/null || { echo "error: kubectl not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq not found" >&2; exit 1; }

printf 'Observability validation (read-only)\n\n'

kubectl get namespace "$NAMESPACE" >/dev/null
kubectl get prometheus -n "$NAMESPACE" "${RELEASE}-prometheus" >/dev/null
kubectl get alertmanager -n "$NAMESPACE" "${RELEASE}-alertmanager" >/dev/null
kubectl get service -n "$NAMESPACE" "${RELEASE}-grafana" >/dev/null

echo 'Waiting only for readiness conditions; no resources will be changed...'
kubectl wait --for=condition=Ready pod -n "$NAMESPACE" --all --timeout=120s >/dev/null

NOT_BOUND="$(kubectl get pvc -n "$NAMESPACE" -o json | jq -r '[.items[] | select(.status.phase != "Bound")] | length')"
if [[ "$NOT_BOUND" != "0" ]]; then
  echo "error: one or more monitoring PVCs are not Bound" >&2
  kubectl get pvc -n "$NAMESPACE" -o wide
  exit 1
fi

PROM_PROXY="/api/v1/namespaces/${NAMESPACE}/services/http:${PROM_SERVICE}:9090/proxy"
TARGETS_JSON="$(kubectl get --raw "${PROM_PROXY}/api/v1/targets?state=active")"

if [[ "$(jq -r '.status' <<<"$TARGETS_JSON")" != "success" ]]; then
  echo "error: Prometheus targets API did not return success" >&2
  exit 1
fi

TOTAL="$(jq '.data.activeTargets | length' <<<"$TARGETS_JSON")"
UP="$(jq '[.data.activeTargets[] | select(.health == "up")] | length' <<<"$TARGETS_JSON")"
DOWN="$((TOTAL - UP))"

if (( TOTAL == 0 )); then
  echo "error: Prometheus reports zero active targets" >&2
  exit 1
fi

printf '\nPrometheus active targets: %s total, %s up, %s not-up\n' "$TOTAL" "$UP" "$DOWN"

if (( DOWN > 0 )); then
  echo
  echo 'Targets not healthy:'
  jq -r '.data.activeTargets[] | select(.health != "up") | "- job=\(.labels.job // "unknown") instance=\(.labels.instance // "unknown") health=\(.health) error=\(.lastError // "")"' <<<"$TARGETS_JSON"
  exit 1
fi

UP_QUERY="$(kubectl get --raw "${PROM_PROXY}/api/v1/query?query=up")"
UP_SERIES="$(jq '.data.result | length' <<<"$UP_QUERY")"
if (( UP_SERIES == 0 )); then
  echo "error: Prometheus query 'up' returned no series" >&2
  exit 1
fi
printf "Prometheus query 'up': %s series\n" "$UP_SERIES"

echo
kubectl get pods -n "$NAMESPACE" -o wide

echo
kubectl get pvc -n "$NAMESPACE" -o wide

echo
if kubectl top nodes >/dev/null 2>&1; then
  echo 'Current node resource usage:'
  kubectl top nodes
  echo
  echo 'Current monitoring pod resource usage:'
  kubectl top pods -n "$NAMESPACE" --containers || true
else
  echo 'INFO: kubectl top is not currently available; metrics-server usage check skipped.'
fi

echo
echo 'Observability validation: OK'
echo 'Prometheus has active healthy scrape targets; monitoring Pods are Ready and PVCs are Bound.'
