#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/kubernetes/apps/otel-go-demo"
IMAGE="${OTEL_GO_DEMO_IMAGE:-guiosoft/otel-go-demo:dev}"
NAMESPACE="${OTEL_GO_DEMO_NAMESPACE:-lab}"
APP_PORT="${OTEL_GO_DEMO_LOCAL_PORT:-18080}"
TEMPO_PORT="${OTEL_GO_DEMO_TEMPO_PORT:-13200}"

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
  kubectl apply -f "$APP_DIR/deployment.yaml"
  kubectl apply -f "$APP_DIR/service.yaml"
  kubectl rollout status deployment/otel-go-demo -n "$NAMESPACE" --timeout=120s
}

status_app() {
  need kubectl
  kubectl get deployment,pod,service -n "$NAMESPACE" -l app=otel-go-demo -o wide
}

trace_test() {
  need kubectl
  need curl
  need jq

  kubectl get deployment -n "$NAMESPACE" otel-go-demo >/dev/null
  kubectl get service -n monitoring tempo >/dev/null

  local app_log tempo_log app_pf tempo_pf response trace_id tempo_response
  app_log="$(mktemp)"
  tempo_log="$(mktemp)"
  tempo_response="$(mktemp)"

  cleanup() {
    [[ -n "${app_pf:-}" ]] && kill "$app_pf" >/dev/null 2>&1 || true
    [[ -n "${tempo_pf:-}" ]] && kill "$tempo_pf" >/dev/null 2>&1 || true
    rm -f "$app_log" "$tempo_log" "$tempo_response"
  }
  trap cleanup EXIT

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
    exit 1
  }
  curl --fail --silent "http://127.0.0.1:${TEMPO_PORT}/ready" >/dev/null || {
    echo "error: Tempo port-forward did not become ready" >&2
    cat "$tempo_log" >&2
    exit 1
  }

  response="$(curl --fail --silent "http://127.0.0.1:${APP_PORT}/work")"
  trace_id="$(jq -r '.trace_id // empty' <<<"$response")"
  [[ "$trace_id" =~ ^[0-9a-f]{32}$ ]] || {
    echo "error: application did not return a valid trace_id" >&2
    echo "$response" >&2
    exit 1
  }

  echo "Trace generated: $trace_id"

  for _ in $(seq 1 20); do
    if curl --fail --silent "http://127.0.0.1:${TEMPO_PORT}/api/traces/${trace_id}" -o "$tempo_response"; then
      if jq -e '(.batches // []) | length > 0' "$tempo_response" >/dev/null 2>&1; then
        echo "Tempo trace lookup: OK"
        echo "Trace ID: $trace_id"
        echo "Open Grafana -> Explore -> Tempo and search this trace ID."
        return 0
      fi
    fi
    sleep 1
  done

  echo "error: trace was not found in Tempo within the validation window" >&2
  [[ -s "$tempo_response" ]] && cat "$tempo_response" >&2 || true
  exit 1
}

delete_app() {
  need kubectl
  kubectl delete -f "$APP_DIR/service.yaml" --ignore-not-found
  kubectl delete -f "$APP_DIR/deployment.yaml" --ignore-not-found
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
  delete)
    delete_app
    ;;
  *)
    echo "Usage: $0 {build|deploy|install|status|test|delete}" >&2
    exit 2
    ;;
esac
