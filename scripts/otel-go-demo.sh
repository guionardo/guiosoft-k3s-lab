#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/kubernetes/apps/otel-go-demo"
IMAGE="${OTEL_GO_DEMO_IMAGE:-guiosoft/otel-go-demo:dev}"
NAMESPACE="${OTEL_GO_DEMO_NAMESPACE:-lab}"
APP_PORT="${OTEL_GO_DEMO_LOCAL_PORT:-18080}"
TEMPO_PORT="${OTEL_GO_DEMO_TEMPO_PORT:-13200}"
PROM_PORT="${OTEL_GO_DEMO_PROM_PORT:-19090}"
PROM_SERVICE="${OTEL_GO_DEMO_PROM_SERVICE:-kube-prometheus-stack-prometheus}"

need() {
  command -v "$1" >/dev/null || { echo "error: required command not found: $1" >&2; exit 1; }
}

build_image() {
  need docker
  need sudo
  need k3s

  echo "Building $IMAGE with Docker..."
  docker build -t "$IMAGE" "$APP_DIR/app"

  local archive
  archive="$(mktemp --suffix=.tar)"
  trap 'rm -f "${archive:-}"' RETURN

  echo "Importing $IMAGE into K3s containerd..."
  docker save "$IMAGE" -o "$archive"
  sudo k3s ctr images import "$archive" >/dev/null
  echo "Image imported into K3s containerd: $IMAGE"
}

deploy_app() {
  need kubectl
  kubectl apply -f "$REPO_ROOT/kubernetes/namespaces/lab.yaml"
  kubectl apply -f "$APP_DIR/downstream-deployment.yaml"
  kubectl apply -f "$APP_DIR/downstream-service.yaml"
  kubectl apply -f "$APP_DIR/deployment.yaml"
  kubectl apply -f "$APP_DIR/service.yaml"
  kubectl apply -f "$APP_DIR/service-monitor.yaml"

  # Both deployments deliberately reuse the local :dev tag with imagePullPolicy: Never.
  # Force rollouts so each local rebuild/import is actually exercised by Kubernetes.
  kubectl rollout restart deployment/otel-go-downstream -n "$NAMESPACE"
  kubectl rollout restart deployment/otel-go-demo -n "$NAMESPACE"
  kubectl rollout status deployment/otel-go-downstream -n "$NAMESPACE" --timeout=120s
  kubectl rollout status deployment/otel-go-demo -n "$NAMESPACE" --timeout=120s
}

status_app() {
  need kubectl
  kubectl get deployment,pod,service -n "$NAMESPACE" -l 'app in (otel-go-demo,otel-go-downstream)' -o wide
  echo
  kubectl get servicemonitor -n monitoring otel-go-demo -o wide
}

trace_test() {
  need kubectl
  need curl
  need jq

  kubectl get deployment -n "$NAMESPACE" otel-go-demo >/dev/null
  kubectl get deployment -n "$NAMESPACE" otel-go-downstream >/dev/null
  kubectl get service -n monitoring tempo >/dev/null

  local app_log tempo_log app_pf tempo_pf response trace_id tempo_response services
  app_log="$(mktemp)"
  tempo_log="$(mktemp)"
  tempo_response="$(mktemp)"
  app_pf=""
  tempo_pf=""

  cleanup() {
    [[ -n "${app_pf:-}" ]] && kill "$app_pf" >/dev/null 2>&1 || true
    [[ -n "${tempo_pf:-}" ]] && kill "$tempo_pf" >/dev/null 2>&1 || true
    rm -f "${app_log:-}" "${tempo_log:-}" "${tempo_response:-}"
  }
  trap cleanup RETURN

  kubectl port-forward -n "$NAMESPACE" service/otel-go-demo "$APP_PORT":8080 >"$app_log" 2>&1 &
  app_pf=$!
  kubectl port-forward -n monitoring service/tempo "$TEMPO_PORT":3200 >"$tempo_log" 2>&1 &
  tempo_pf=$!

  for _ in $(seq 1 30); do
    if curl --fail --silent "http://127.0.0.1:${APP_PORT}/healthz" >/dev/null 2>&1 && \
       curl --fail --silent "http://127.0.0.1:${TEMPO_PORT}/ready" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  curl --fail --silent "http://127.0.0.1:${APP_PORT}/healthz" >/dev/null || {
    echo "error: application port-forward did not become ready" >&2
    cat "$app_log" >&2
    return 1
  }
  curl --fail --silent "http://127.0.0.1:${TEMPO_PORT}/ready" >/dev/null || {
    echo "error: Tempo port-forward did not become ready" >&2
    cat "$tempo_log" >&2
    return 1
  }

  response="$(curl --fail --silent "http://127.0.0.1:${APP_PORT}/work")"
  trace_id="$(jq -r '.trace_id // empty' <<<"$response")"
  [[ "$trace_id" =~ ^[0-9a-f]{32}$ ]] || {
    echo "error: application did not return a valid trace_id" >&2
    echo "$response" >&2
    return 1
  }
  if [[ "$(jq -r '.downstream // empty' <<<"$response")" != "ok" ]]; then
    echo "error: frontend did not confirm downstream call" >&2
    echo "$response" >&2
    return 1
  fi

  echo "Distributed trace generated: $trace_id"

  for _ in $(seq 1 30); do
    if curl --fail --silent "http://127.0.0.1:${TEMPO_PORT}/api/traces/${trace_id}" -o "$tempo_response"; then
      if jq -e '(.batches // []) | length > 0' "$tempo_response" >/dev/null 2>&1; then
        services="$(jq -r '[.. | objects | select(.key? == "service.name") | .value.stringValue? // empty] | unique | .[]' "$tempo_response" 2>/dev/null || true)"
        if grep -qx 'otel-go-demo' <<<"$services" && grep -qx 'otel-go-downstream' <<<"$services"; then
          echo "Tempo distributed trace lookup: OK"
          echo "Trace ID: $trace_id"
          echo "Services in trace:"
          printf '%s\n' "$services" | sed 's/^/- /'
          echo "Open Grafana -> Explore -> Tempo and search this trace ID to inspect the service graph."
          return 0
        fi
      fi
    fi
    sleep 1
  done

  echo "error: trace did not contain both otel-go-demo and otel-go-downstream within the validation window" >&2
  [[ -s "$tempo_response" ]] && jq '[.. | objects | select(.key? == "service.name") | .value.stringValue? // empty] | unique' "$tempo_response" >&2 || true
  return 1
}

metrics_test() {
  need kubectl
  need curl
  need jq

  kubectl get deployment -n "$NAMESPACE" otel-go-demo >/dev/null
  kubectl get deployment -n "$NAMESPACE" otel-go-downstream >/dev/null
  kubectl get servicemonitor -n monitoring otel-go-demo >/dev/null
  kubectl get service -n monitoring "$PROM_SERVICE" >/dev/null

  local app_log prom_log app_pf prom_pf metrics query response value
  app_log="$(mktemp)"
  prom_log="$(mktemp)"
  app_pf=""
  prom_pf=""

  cleanup() {
    [[ -n "${app_pf:-}" ]] && kill "$app_pf" >/dev/null 2>&1 || true
    [[ -n "${prom_pf:-}" ]] && kill "$prom_pf" >/dev/null 2>&1 || true
    rm -f "${app_log:-}" "${prom_log:-}"
  }
  trap cleanup RETURN

  kubectl port-forward -n "$NAMESPACE" service/otel-go-demo "$APP_PORT":8080 >"$app_log" 2>&1 &
  app_pf=$!
  kubectl port-forward -n monitoring service/"$PROM_SERVICE" "$PROM_PORT":9090 >"$prom_log" 2>&1 &
  prom_pf=$!

  for _ in $(seq 1 30); do
    if curl --fail --silent "http://127.0.0.1:${APP_PORT}/metrics" >/dev/null 2>&1 && \
       curl --fail --silent "http://127.0.0.1:${PROM_PORT}/-/ready" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  # CounterVec/HistogramVec series are created lazily by client_golang when a
  # concrete label set is first observed. Validate that /metrics is alive first,
  # then generate traffic before requiring the custom vector families to appear.
  metrics="$(curl --fail --silent "http://127.0.0.1:${APP_PORT}/metrics")" || {
    echo "error: application metrics endpoint did not become ready" >&2
    cat "$app_log" >&2
    return 1
  }
  grep -q '^# HELP go_' <<<"$metrics" || {
    echo "error: /metrics responded but does not look like a Prometheus client endpoint" >&2
    return 1
  }

  echo "Generating demo traffic..."
  for _ in $(seq 1 8); do
    curl --fail --silent "http://127.0.0.1:${APP_PORT}/work" >/dev/null
  done

  metrics="$(curl --fail --silent "http://127.0.0.1:${APP_PORT}/metrics")"
  grep -q '^# HELP otel_demo_http_requests_total ' <<<"$metrics" || {
    echo "error: custom HTTP metric did not appear after generating traffic" >&2
    return 1
  }
  grep -q '^# HELP otel_demo_http_request_duration_seconds ' <<<"$metrics" || {
    echo "error: custom HTTP duration histogram did not appear after generating traffic" >&2
    return 1
  }
  grep -q '^# HELP otel_demo_downstream_requests_total ' <<<"$metrics" || {
    echo "error: custom downstream metric did not appear after generating traffic" >&2
    return 1
  }

  prom_query_value() {
    local q="$1"
    curl --fail --silent --get \
      --data-urlencode "query=$q" \
      "http://127.0.0.1:${PROM_PORT}/api/v1/query" \
      | jq -r 'if .status == "success" and (.data.result | length) > 0 then .data.result[0].value[1] else empty end'
  }

  for _ in $(seq 1 18); do
    query='sum(otel_demo_http_requests_total{service="otel-go-demo",path="/work"})'
    value="$(prom_query_value "$query" || true)"
    if [[ -n "$value" ]] && awk "BEGIN { exit !($value > 0) }"; then
      break
    fi
    sleep 5
  done

  [[ -n "${value:-}" ]] && awk "BEGIN { exit !($value > 0) }" || {
    echo "error: Prometheus did not ingest otel_demo_http_requests_total within the validation window" >&2
    return 1
  }

  echo "Prometheus custom metrics:"
  for query in \
    'sum(otel_demo_http_requests_total{service="otel-go-demo",path="/work"})' \
    'count(otel_demo_http_request_duration_seconds_bucket{service="otel-go-demo",path="/work"})' \
    'sum(otel_demo_downstream_requests_total{service="otel-go-demo",status="ok"})' \
    'sum(otel_demo_http_requests_total{service="otel-go-downstream",path="/process"})'; do
    response="$(curl --fail --silent --get --data-urlencode "query=$query" "http://127.0.0.1:${PROM_PORT}/api/v1/query")"
    value="$(jq -r 'if .status == "success" and (.data.result | length) > 0 then .data.result[0].value[1] else empty end' <<<"$response")"
    if [[ -z "$value" ]] || ! awk "BEGIN { exit !($value > 0) }"; then
      echo "error: Prometheus query did not return a positive value: $query" >&2
      echo "$response" >&2
      return 1
    fi
    printf '  %-86s %s\n' "$query" "$value"
  done

  echo
  echo "Custom metrics validation: OK"
  echo "Prometheus is scraping /metrics from both demo services through ServiceMonitor/otel-go-demo."
  echo "Try in Grafana Explore -> Prometheus: rate(otel_demo_http_requests_total[5m])"
}

delete_app() {
  need kubectl
  kubectl delete -f "$APP_DIR/service-monitor.yaml" --ignore-not-found
  kubectl delete -f "$APP_DIR/service.yaml" --ignore-not-found
  kubectl delete -f "$APP_DIR/deployment.yaml" --ignore-not-found
  kubectl delete -f "$APP_DIR/downstream-service.yaml" --ignore-not-found
  kubectl delete -f "$APP_DIR/downstream-deployment.yaml" --ignore-not-found
}

case "$ACTION" in
  build)
    build_image
    ;;
  deploy)
    deploy_app
    ;;
  install)
    build_image
    deploy_app
    status_app
    ;;
  status)
    status_app
    ;;
  test)
    trace_test
    ;;
  metrics-test)
    metrics_test
    ;;
  delete)
    delete_app
    ;;
  *)
    echo "Usage: $0 {build|deploy|install|status|test|metrics-test|delete}" >&2
    exit 2
    ;;
esac
