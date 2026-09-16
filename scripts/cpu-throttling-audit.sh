#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
PROM_SERVICE="${OBSERVABILITY_PROM_SERVICE:-kube-prometheus-stack-prometheus}"
POD_REGEX="${CPU_THROTTLING_POD_REGEX:-kube-prometheus-stack-prometheus-node-exporter-.*}"

for cmd in kubectl jq; do
  command -v "$cmd" >/dev/null || { echo "error: required command not found: $cmd" >&2; exit 1; }
done

PROM_PROXY="/api/v1/namespaces/${NAMESPACE}/services/http:${PROM_SERVICE}:9090/proxy"

prom_query() {
  local query="$1"
  local encoded
  encoded="$(jq -rn --arg q "$query" '$q|@uri')"
  kubectl get --raw "${PROM_PROXY}/api/v1/query?query=${encoded}"
}

printf 'CPU throttling audit (read-only)\n\n'

RULES_JSON="$(kubectl get --raw "${PROM_PROXY}/api/v1/rules?type=alert")"
RULE_EXPR="$(jq -r '[.data.groups[].rules[] | select(.name == "CPUThrottlingHigh")][0].query // empty' <<<"$RULES_JSON")"
RULE_FOR="$(jq -r '[.data.groups[].rules[] | select(.name == "CPUThrottlingHigh")][0].duration // empty' <<<"$RULES_JSON")"

if [[ -n "$RULE_EXPR" ]]; then
  echo 'Effective Prometheus rule:'
  printf '  alert: CPUThrottlingHigh\n'
  printf '  for:   %s\n' "${RULE_FOR:-n/a}"
  printf '  expr:  %s\n\n' "$RULE_EXPR"
else
  echo 'INFO: CPUThrottlingHigh rule was not found in the Prometheus rules API.'
  echo
fi

THROTTLE_QUERY="100 * sum by (namespace, pod, container) (increase(container_cpu_cfs_throttled_periods_total{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\",container!=\"\"}[5m])) / sum by (namespace, pod, container) (increase(container_cpu_cfs_periods_total{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\",container!=\"\"}[5m]))"
CPU_QUERY="sum by (namespace, pod, container) (rate(container_cpu_usage_seconds_total{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\",container!=\"\"}[5m]))"
LIMIT_QUERY="kube_pod_container_resource_limits{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\",resource=\"cpu\",unit=\"core\"}"
REQUEST_QUERY="kube_pod_container_resource_requests{namespace=\"${NAMESPACE}\",pod=~\"${POD_REGEX}\",resource=\"cpu\",unit=\"core\"}"

THROTTLE_JSON="$(prom_query "$THROTTLE_QUERY")"
CPU_JSON="$(prom_query "$CPU_QUERY")"
LIMIT_JSON="$(prom_query "$LIMIT_QUERY")"
REQUEST_JSON="$(prom_query "$REQUEST_QUERY")"

echo 'Current 5-minute throttling ratio:'
if jq -e '.data.result | length > 0' <<<"$THROTTLE_JSON" >/dev/null; then
  jq -r '.data.result[] | "- pod=\(.metric.pod // "n/a") container=\(.metric.container // "n/a") throttled=\((.value[1] | tonumber) | tostring)%"' <<<"$THROTTLE_JSON"
else
  echo '- no matching throttling series found'
fi

echo
echo 'Current 5-minute average CPU usage:'
if jq -e '.data.result | length > 0' <<<"$CPU_JSON" >/dev/null; then
  jq -r '.data.result[] | "- pod=\(.metric.pod // "n/a") container=\(.metric.container // "n/a") cpu_cores=\(.value[1])"' <<<"$CPU_JSON"
else
  echo '- no matching CPU usage series found'
fi

echo
echo 'Configured CPU requests:'
if jq -e '.data.result | length > 0' <<<"$REQUEST_JSON" >/dev/null; then
  jq -r '.data.result[] | "- pod=\(.metric.pod // "n/a") container=\(.metric.container // "n/a") request_cores=\(.value[1])"' <<<"$REQUEST_JSON"
else
  echo '- no CPU request series found'
fi

echo
echo 'Configured CPU limits:'
if jq -e '.data.result | length > 0' <<<"$LIMIT_JSON" >/dev/null; then
  jq -r '.data.result[] | "- pod=\(.metric.pod // "n/a") container=\(.metric.container // "n/a") limit_cores=\(.value[1])"' <<<"$LIMIT_JSON"
else
  echo '- no CPU limit series found'
fi

echo
echo 'Current CPUThrottlingHigh alert state:'
ALERTS_JSON="$(kubectl get --raw "${PROM_PROXY}/api/v1/alerts")"
if jq -e '[.data.alerts[] | select(.labels.alertname == "CPUThrottlingHigh")] | length > 0' <<<"$ALERTS_JSON" >/dev/null; then
  jq -r '.data.alerts[] | select(.labels.alertname == "CPUThrottlingHigh") | "- state=\(.state) pod=\(.labels.pod // "n/a") container=\(.labels.container // "n/a") activeAt=\(.activeAt // "n/a")"' <<<"$ALERTS_JSON"
else
  echo '- not active'
fi

echo
echo 'Interpretation guide:'
echo '- high throttling with low average CPU can indicate short bursts hitting a tight CFS CPU limit;'
echo '- persistent high throttling plus latency/throughput impact is stronger evidence of an undersized limit;'
echo '- this audit is read-only and does not change limits or alert rules.'
