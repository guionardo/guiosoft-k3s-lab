#!/usr/bin/env bash
set -euo pipefail

APP_NAMESPACE="${OTEL_GO_DEMO_NAMESPACE:-lab}"
MON_NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
APP_PORT="${OTEL_GO_DEMO_LOCAL_PORT:-18080}"
PROM_PORT="${OTEL_GO_DEMO_PROM_PORT:-19090}"
LOKI_PORT="${LOKI_LOCAL_PORT:-13100}"
TEMPO_PORT="${OTEL_GO_DEMO_TEMPO_PORT:-13200}"
PROM_SERVICE="${OTEL_GO_DEMO_PROM_SERVICE:-kube-prometheus-stack-prometheus}"
FAILURE_REQUESTS="${OTEL_GO_DEMO_FAILURE_REQUESTS:-12}"

need() {
  command -v "$1" >/dev/null || { echo "error: required command not found: $1" >&2; exit 1; }
}

for cmd in kubectl curl jq awk; do
  need "$cmd"
done

kubectl get deployment -n "$APP_NAMESPACE" otel-go-demo >/dev/null
kubectl get deployment -n "$APP_NAMESPACE" otel-go-downstream >/dev/null
kubectl get service -n "$APP_NAMESPACE" otel-go-demo >/dev/null
kubectl get service -n "$MON_NAMESPACE" "$PROM_SERVICE" >/dev/null
kubectl get service -n "$MON_NAMESPACE" loki-gateway >/dev/null
kubectl get service -n "$MON_NAMESPACE" tempo >/dev/null

original_replicas="$(kubectl get deployment -n "$APP_NAMESPACE" otel-go-downstream -o jsonpath='{.spec.replicas}')"
[[ "$original_replicas" =~ ^[0-9]+$ ]] || { echo "error: could not determine downstream replica count" >&2; exit 1; }

app_log="$(mktemp)"
prom_log="$(mktemp)"
loki_log="$(mktemp)"
tempo_log="$(mktemp)"
body_file="$(mktemp)"
app_pf=""
prom_pf=""
loki_pf=""
tempo_pf=""
restored=0

restore_downstream() {
  if [[ "$restored" -eq 0 ]]; then
    echo "Restoring otel-go-downstream replicas to $original_replicas..."
    kubectl scale deployment/otel-go-downstream -n "$APP_NAMESPACE" --replicas="$original_replicas" >/dev/null || true
    if [[ "$original_replicas" -gt 0 ]]; then
      kubectl rollout status deployment/otel-go-downstream -n "$APP_NAMESPACE" --timeout=120s >/dev/null || true
    fi
    restored=1
  fi
}

cleanup() {
  restore_downstream
  [[ -n "$app_pf" ]] && kill "$app_pf" >/dev/null 2>&1 || true
  [[ -n "$prom_pf" ]] && kill "$prom_pf" >/dev/null 2>&1 || true
  [[ -n "$loki_pf" ]] && kill "$loki_pf" >/dev/null 2>&1 || true
  [[ -n "$tempo_pf" ]] && kill "$tempo_pf" >/dev/null 2>&1 || true
  rm -f "$app_log" "$prom_log" "$loki_log" "$tempo_log" "$body_file"
}
trap cleanup EXIT INT TERM

kubectl port-forward -n "$APP_NAMESPACE" service/otel-go-demo "$APP_PORT":8080 >"$app_log" 2>&1 &
app_pf=$!
kubectl port-forward -n "$MON_NAMESPACE" service/"$PROM_SERVICE" "$PROM_PORT":9090 >"$prom_log" 2>&1 &
prom_pf=$!
kubectl port-forward -n "$MON_NAMESPACE" service/loki-gateway "$LOKI_PORT":80 >"$loki_log" 2>&1 &
loki_pf=$!
kubectl port-forward -n "$MON_NAMESPACE" service/tempo "$TEMPO_PORT":3200 >"$tempo_log" 2>&1 &
tempo_pf=$!

for _ in $(seq 1 30); do
  if curl --fail --silent "http://127.0.0.1:${APP_PORT}/healthz" >/dev/null 2>&1 && \
     curl --fail --silent "http://127.0.0.1:${PROM_PORT}/-/ready" >/dev/null 2>&1 && \
     curl --fail --silent "http://127.0.0.1:${LOKI_PORT}/loki/api/v1/status/buildinfo" >/dev/null 2>&1 && \
     curl --fail --silent "http://127.0.0.1:${TEMPO_PORT}/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

curl --fail --silent "http://127.0.0.1:${APP_PORT}/healthz" >/dev/null || { echo "error: app port-forward not ready" >&2; exit 1; }
curl --fail --silent "http://127.0.0.1:${PROM_PORT}/-/ready" >/dev/null || { echo "error: Prometheus port-forward not ready" >&2; exit 1; }
curl --fail --silent "http://127.0.0.1:${LOKI_PORT}/loki/api/v1/status/buildinfo" >/dev/null || { echo "error: Loki port-forward not ready" >&2; exit 1; }
curl --fail --silent "http://127.0.0.1:${TEMPO_PORT}/ready" >/dev/null || { echo "error: Tempo port-forward not ready" >&2; exit 1; }

echo "Injecting controlled failure: scaling otel-go-downstream to 0 replicas..."
kubectl scale deployment/otel-go-downstream -n "$APP_NAMESPACE" --replicas=0 >/dev/null
kubectl wait --for=delete pod -n "$APP_NAMESPACE" -l app=otel-go-downstream --timeout=90s >/dev/null 2>&1 || true

trace_id=""
for i in $(seq 1 "$FAILURE_REQUESTS"); do
  http_code="$(curl --silent --show-error -o "$body_file" -w '%{http_code}' "http://127.0.0.1:${APP_PORT}/work" || true)"
  if [[ "$http_code" != "502" ]]; then
    echo "error: expected HTTP 502 during controlled failure, got $http_code on request $i" >&2
    cat "$body_file" >&2 || true
    exit 1
  fi
  if [[ -z "$trace_id" ]]; then
    trace_id="$(jq -r '.trace_id // empty' "$body_file")"
  fi
done

[[ "$trace_id" =~ ^[0-9a-f]{32}$ ]] || {
  echo "error: failed request did not return a valid trace_id" >&2
  cat "$body_file" >&2 || true
  exit 1
}

echo "Controlled failure generated $FAILURE_REQUESTS HTTP 502 responses."
echo "Incident trace ID: $trace_id"

prom_query() {
  local q="$1"
  curl --fail --silent --get --data-urlencode "query=$q" "http://127.0.0.1:${PROM_PORT}/api/v1/query"
}

metric_ok=0
for _ in $(seq 1 24); do
  err_value="$(prom_query 'sum(increase(otel_demo_downstream_errors_total{service="otel-go-demo"}[5m]))' | jq -r 'if .status=="success" and (.data.result|length)>0 then .data.result[0].value[1] else empty end' || true)"
  http_value="$(prom_query 'sum(increase(otel_demo_http_requests_total{service="otel-go-demo",path="/work",status="502"}[5m]))' | jq -r 'if .status=="success" and (.data.result|length)>0 then .data.result[0].value[1] else empty end' || true)"
  if [[ -n "$err_value" && -n "$http_value" ]] && awk "BEGIN { exit !(($err_value > 0) && ($http_value > 0)) }"; then
    metric_ok=1
    break
  fi
  sleep 5
done
[[ "$metric_ok" -eq 1 ]] || { echo "error: incident metrics were not ingested by Prometheus" >&2; exit 1; }
echo "Prometheus incident metrics: OK (downstream errors + HTTP 502)."

alert_ok=0
alert_state=""
for _ in $(seq 1 24); do
  rules_json="$(curl --fail --silent "http://127.0.0.1:${PROM_PORT}/api/v1/rules?type=alert" || true)"
  alert_state="$(jq -r '[.data.groups[].rules[]? | select(.name=="OtelGoDemoDownstreamErrors") | .alerts[]?.state] | first // empty' <<<"$rules_json" 2>/dev/null || true)"
  if [[ "$alert_state" == "pending" || "$alert_state" == "firing" ]]; then
    alert_ok=1
    break
  fi
  sleep 5
done
[[ "$alert_ok" -eq 1 ]] || { echo "error: OtelGoDemoDownstreamErrors did not become pending/firing" >&2; exit 1; }
echo "Prometheus alert state: $alert_state (OtelGoDemoDownstreamErrors)."

encoded_query="$(jq -rn --arg q "{namespace=\"${APP_NAMESPACE}\",app=\"otel-go-demo\"} |= \"${trace_id}\"" '$q|@uri')"
log_ok=0
for _ in $(seq 1 30); do
  result="$(curl --fail --silent "http://127.0.0.1:${LOKI_PORT}/loki/api/v1/query_range?query=${encoded_query}&limit=20" || true)"
  if [[ -n "$result" ]] && jq -e '.status == "success" and (.data.result | length > 0)' <<<"$result" >/dev/null 2>&1; then
    log_ok=1
    break
  fi
  sleep 1
done
[[ "$log_ok" -eq 1 ]] || { echo "error: incident trace_id was not found in Loki" >&2; exit 1; }
echo "Loki incident log lookup: OK."

trace_ok=0
tempo_response="$(mktemp)"
for _ in $(seq 1 30); do
  if curl --fail --silent "http://127.0.0.1:${TEMPO_PORT}/api/traces/${trace_id}" -o "$tempo_response"; then
    if jq -e '[.. | objects | select(.key? == "service.name") | .value.stringValue? // empty] | any(. == "otel-go-demo")' "$tempo_response" >/dev/null 2>&1; then
      trace_ok=1
      break
    fi
  fi
  sleep 1
done
rm -f "$tempo_response"
[[ "$trace_ok" -eq 1 ]] || { echo "error: incident trace was not found in Tempo" >&2; exit 1; }
echo "Tempo incident trace lookup: OK."

restore_downstream

for _ in $(seq 1 30); do
  if curl --fail --silent "http://127.0.0.1:${APP_PORT}/work" | jq -e '.downstream == "ok"' >/dev/null 2>&1; then
    echo "Recovery request: OK."
    echo
    echo "Controlled observability incident drill: OK"
    echo "Validated chain: HTTP 502 -> Prometheus metrics -> alert pending/firing -> Loki log -> Tempo trace -> downstream recovery."
    echo "Use Grafana dashboard 'OTel Go Demo - Application Metrics' and trace ID $trace_id to inspect the incident visually."
    exit 0
  fi
  sleep 2
done

echo "error: downstream was restored but frontend did not recover within the validation window" >&2
exit 1
