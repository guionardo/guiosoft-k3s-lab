#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-validate}"
NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
GRAFANA_SERVICE="${GRAFANA_SERVICE:-kube-prometheus-stack-grafana}"
GRAFANA_SECRET="${GRAFANA_SECRET:-kube-prometheus-stack-grafana}"
LOCAL_PORT="${GRAFANA_LOCAL_PORT:-13000}"

need() {
  command -v "$1" >/dev/null || { echo "error: required command not found: $1" >&2; exit 1; }
}

restart_grafana() {
  need kubectl

  if kubectl get statefulset -n "$NAMESPACE" "$GRAFANA_SERVICE" >/dev/null 2>&1; then
    echo "Restarting Grafana StatefulSet so datasource provisioning is reloaded..."
    kubectl rollout restart statefulset/"$GRAFANA_SERVICE" -n "$NAMESPACE"
    kubectl rollout status statefulset/"$GRAFANA_SERVICE" -n "$NAMESPACE" --timeout=180s
    return
  fi

  if kubectl get deployment -n "$NAMESPACE" "$GRAFANA_SERVICE" >/dev/null 2>&1; then
    echo "Restarting Grafana Deployment so datasource provisioning is reloaded..."
    kubectl rollout restart deployment/"$GRAFANA_SERVICE" -n "$NAMESPACE"
    kubectl rollout status deployment/"$GRAFANA_SERVICE" -n "$NAMESPACE" --timeout=180s
    return
  fi

  echo "error: Grafana workload '$GRAFANA_SERVICE' not found as StatefulSet or Deployment" >&2
  exit 1
}

validate_datasources() {
  need kubectl
  need curl
  need jq

  local user password pf_log pf_pid datasources
  user="$(kubectl get secret -n "$NAMESPACE" "$GRAFANA_SECRET" -o jsonpath='{.data.admin-user}' | base64 -d)"
  password="$(kubectl get secret -n "$NAMESPACE" "$GRAFANA_SECRET" -o jsonpath='{.data.admin-password}' | base64 -d)"
  pf_log="$(mktemp)"
  pf_pid=""

  cleanup() {
    [[ -n "${pf_pid:-}" ]] && kill "$pf_pid" >/dev/null 2>&1 || true
    rm -f "$pf_log"
  }
  trap cleanup RETURN

  kubectl port-forward -n "$NAMESPACE" service/"$GRAFANA_SERVICE" "$LOCAL_PORT":80 >"$pf_log" 2>&1 &
  pf_pid=$!

  for _ in $(seq 1 30); do
    if curl --fail --silent "http://127.0.0.1:${LOCAL_PORT}/api/health" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  curl --fail --silent "http://127.0.0.1:${LOCAL_PORT}/api/health" >/dev/null || {
    echo "error: Grafana port-forward did not become ready" >&2
    cat "$pf_log" >&2
    return 1
  }

  datasources="$(curl --fail --silent --user "$user:$password" "http://127.0.0.1:${LOCAL_PORT}/api/datasources")"

  printf '%-12s %-12s %-10s\n' NAME UID TYPE
  jq -r '.[] | [.name, .uid, .type] | @tsv' <<<"$datasources" | while IFS=$'\t' read -r name uid type; do
    printf '%-12s %-12s %-10s\n' "$name" "$uid" "$type"
  done

  for uid in prometheus tempo loki; do
    if ! jq -e --arg uid "$uid" '.[] | select(.uid == $uid)' <<<"$datasources" >/dev/null; then
      echo "error: expected Grafana datasource uid '$uid' was not found" >&2
      return 1
    fi
  done

  echo
  echo "Datasource provisioning: OK (prometheus, tempo, loki)"

  for uid in prometheus tempo loki; do
    if health="$(curl --fail --silent --user "$user:$password" "http://127.0.0.1:${LOCAL_PORT}/api/datasources/uid/${uid}/health" 2>/dev/null)"; then
      status="$(jq -r '.status // .message // "ok"' <<<"$health" 2>/dev/null || echo ok)"
      echo "$uid health: $status"
    else
      echo "$uid health: endpoint unavailable or backend check failed" >&2
    fi
  done
}

case "$ACTION" in
  reload)
    restart_grafana
    ;;
  validate)
    validate_datasources
    ;;
  reload-and-validate)
    restart_grafana
    validate_datasources
    ;;
  *)
    echo "Usage: $0 {reload|validate|reload-and-validate}" >&2
    exit 2
    ;;
esac
