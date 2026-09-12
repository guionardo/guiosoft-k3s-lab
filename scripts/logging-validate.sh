#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
LOKI_LOCAL_PORT="${LOKI_LOCAL_PORT:-13100}"
APP_NAMESPACE="${OTEL_GO_DEMO_NAMESPACE:-lab}"
APP_LOCAL_PORT="${OTEL_GO_DEMO_LOCAL_PORT:-18080}"

for cmd in kubectl curl jq; do
  command -v "$cmd" >/dev/null || { echo "error: required command not found: $cmd" >&2; exit 1; }
done

kubectl get service -n "$NAMESPACE" loki-gateway >/dev/null
kubectl get service -n "$APP_NAMESPACE" otel-go-demo >/dev/null

local_loki_log="$(mktemp)"
local_app_log="$(mktemp)"
loki_pf=""
app_pf=""
cleanup() {
  [[ -n "$loki_pf" ]] && kill "$loki_pf" >/dev/null 2>&1 || true
  [[ -n "$app_pf" ]] && kill "$app_pf" >/dev/null 2>&1 || true
  rm -f "$local_loki_log" "$local_app_log"
}
trap cleanup EXIT

kubectl port-forward -n "$NAMESPACE" service/loki-gateway "$LOKI_LOCAL_PORT":80 >"$local_loki_log" 2>&1 &
loki_pf=$!
kubectl port-forward -n "$APP_NAMESPACE" service/otel-go-demo "$APP_LOCAL_PORT":8080 >"$local_app_log" 2>&1 &
app_pf=$!

for _ in $(seq 1 30); do
  if curl --fail --silent "http://127.0.0.1:${LOKI_LOCAL_PORT}/ready" >/dev/null 2>&1 && \
     curl --fail --silent "http://127.0.0.1:${APP_LOCAL_PORT}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

curl --fail --silent "http://127.0.0.1:${LOKI_LOCAL_PORT}/ready" >/dev/null || {
  echo "error: Loki gateway did not become ready" >&2
  cat "$local_loki_log" >&2
  exit 1
}
curl --fail --silent "http://127.0.0.1:${APP_LOCAL_PORT}/healthz" >/dev/null || {
  echo "error: otel-go-demo did not become ready" >&2
  cat "$local_app_log" >&2
  exit 1
}

response="$(curl --fail --silent "http://127.0.0.1:${APP_LOCAL_PORT}/work")"
trace_id="$(jq -r '.trace_id // empty' <<<"$response")"
[[ "$trace_id" =~ ^[0-9a-f]{32}$ ]] || {
  echo "error: demo did not return a valid trace_id" >&2
  echo "$response" >&2
  exit 1
}

echo "Trace generated for log correlation: $trace_id"

query="{namespace=\"${APP_NAMESPACE}\",app=\"otel-go-demo\"} |= \"${trace_id}\""
encoded_query="$(jq -rn --arg q "$query" '$q|@uri')"

for _ in $(seq 1 30); do
  result="$(curl --fail --silent "http://127.0.0.1:${LOKI_LOCAL_PORT}/loki/api/v1/query_range?query=${encoded_query}&limit=20" || true)"
  if [[ -n "$result" ]] && jq -e '.status == "success" and (.data.result | length > 0)' <<<"$result" >/dev/null 2>&1; then
    echo "Loki log lookup: OK"
    echo "Trace ID found in logs: $trace_id"
    echo 'Grafana path: Explore -> Loki -> query by app/namespace, then open the TraceID derived field link to Tempo.'
    exit 0
  fi
  sleep 1
done

echo "error: trace_id was not found in Loki within the validation window" >&2
exit 1
