#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-validate}"
APP_DIR="${FIRECRAWL_APP_DIR:-kubernetes/apps/firecrawl}"
NAMESPACE="${FIRECRAWL_NAMESPACE:-firecrawl}"
EXPECTED_HOST="${FIRECRAWL_HOST:-firecrawl.guiosoft.info}"

need() {
  command -v "$1" >/dev/null || { echo "error: required command not found: $1" >&2; exit 1; }
}

validate() {
  need kubectl

  echo "Firecrawl Kubernetes scaffold validation (read-only)"
  echo

  rendered="$(mktemp)"
  trap 'rm -f "$rendered"' RETURN
  kubectl kustomize "$APP_DIR" >"$rendered"

  echo "Rendered manifests: OK"
  kubectl apply --dry-run=client -f "$rendered" >/dev/null
  echo "kubectl client-side dry-run: OK"

  if ! grep -Eq '^kind: Ingress$' "$rendered"; then
    echo "error: Firecrawl Ingress is missing" >&2
    return 1
  fi
  if ! grep -Fq "host: $EXPECTED_HOST" "$rendered"; then
    echo "error: expected Firecrawl hostname not found: $EXPECTED_HOST" >&2
    return 1
  fi
  echo "Public Ingress: $EXPECTED_HOST via ingressClassName=traefik"

  echo
  echo "Images referenced:"
  awk '/^[[:space:]]+image:/ {print "- " $2}' "$rendered" | sort -u

  echo
  echo "Floating image references:"
  floating=0
  while read -r image; do
    [[ -n "$image" ]] || continue
    if [[ "$image" != *@sha256:* ]]; then
      echo "- $image"
      floating=1
    fi
  done < <(awk '/^[[:space:]]+image:/ {print $2}' "$rendered" | sort -u)
  if (( floating == 0 )); then
    echo "- none (all runtime images pinned by digest)"
  fi

  echo
  echo "PersistentVolumeClaims:"
  pvc_count="$(grep -Ec '^kind: PersistentVolumeClaim$' "$rendered" || true)"
  if (( pvc_count == 0 )); then
    echo "- none"
    echo "- PostgreSQL, Redis and RabbitMQ intentionally use emptyDir in the current Firecrawl profile"
  else
    echo "error: current Firecrawl profile is expected to be ephemeral but PVCs were rendered" >&2
    return 1
  fi

  echo
  echo "Secret handling:"
  echo "- plaintext example only: $APP_DIR/secret.example.yaml"
  echo "- runtime secret name expected: firecrawl-secrets"
  echo "- create encrypted secret separately with SOPS + age before deployment"

  echo
  echo "Public exposure note:"
  echo "- $EXPECTED_HOST will be reachable through the existing *.guiosoft.info Cloudflare Tunnel path once deployed"
  echo "- no authentication middleware is added by this Ingress; protect the API separately if public anonymous use is not intended"

  echo
  echo "Firecrawl scaffold validation: OK"
  echo "No Docker or Kubernetes resources were changed."
}

status() {
  need kubectl
  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Firecrawl namespace '$NAMESPACE' does not exist yet."
    exit 0
  fi
  kubectl get deploy,pods,svc,ingress -n "$NAMESPACE" -o wide
}

deploy() {
  need kubectl

  echo "Firecrawl Kubernetes deploy"
  echo

  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "error: namespace '$NAMESPACE' does not exist" >&2
    echo "Apply $APP_DIR/namespace.yaml first." >&2
    exit 1
  fi

  if ! kubectl get secret -n "$NAMESPACE" firecrawl-secrets >/dev/null 2>&1; then
    echo "error: required Secret '$NAMESPACE/firecrawl-secrets' does not exist" >&2
    echo "Generate/apply the SOPS Secret before deploying the stack." >&2
    exit 1
  fi

  validate
  echo
  echo "Applying Firecrawl manifests..."
  kubectl apply -k "$APP_DIR"

  echo
  echo "Waiting for deployments..."
  for deployment in nuq-postgres redis rabbitmq playwright-service firecrawl-api; do
    echo "- deployment/$deployment"
    kubectl rollout status -n "$NAMESPACE" "deployment/$deployment" --timeout=240s
  done

  echo
  echo "Firecrawl deploy completed."
  echo "Docker Compose was not modified or stopped."
  echo
  status
}

test_path() {
  need kubectl
  need curl

  echo "Firecrawl runtime validation"
  echo

  for deployment in nuq-postgres redis rabbitmq playwright-service firecrawl-api; do
    desired="$(kubectl get deployment -n "$NAMESPACE" "$deployment" -o jsonpath='{.spec.replicas}')"
    available="$(kubectl get deployment -n "$NAMESPACE" "$deployment" -o jsonpath='{.status.availableReplicas}')"
    available="${available:-0}"
    if [[ "$available" != "$desired" ]]; then
      echo "error: deployment/$deployment available=$available desired=$desired" >&2
      return 1
    fi
    echo "deployment/$deployment: ready ($available/$desired)"
  done

  endpoint_count="$(kubectl get endpoints -n "$NAMESPACE" firecrawl-api -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | wc -l)"
  if (( endpoint_count < 1 )); then
    echo "error: service/firecrawl-api has no ready endpoints" >&2
    return 1
  fi
  echo "service/firecrawl-api: $endpoint_count ready endpoint(s)"

  echo
  echo "Testing local Traefik path with Host: $EXPECTED_HOST"
  local_body="$(mktemp)"
  trap 'rm -f "$local_body"' RETURN
  local_code="$(curl --silent --show-error --connect-timeout 5 --max-time 15 -o "$local_body" -w '%{http_code}' -H "Host: $EXPECTED_HOST" http://127.0.0.1/)"
  if [[ "$local_code" != "200" ]] || ! grep -Fq 'Firecrawl API' "$local_body"; then
    echo "error: local Traefik request failed validation (HTTP $local_code)" >&2
    echo "Response body follows:" >&2
    cat "$local_body" >&2
    return 1
  fi
  echo "local Traefik -> Ingress -> Service -> API: HTTP 200 / Firecrawl API"

  echo
  echo "Testing public Cloudflare path: https://$EXPECTED_HOST/"
  public_body="$(mktemp)"
  trap 'rm -f "$local_body" "$public_body"' RETURN
  public_code="$(curl --silent --show-error --connect-timeout 10 --max-time 30 -o "$public_body" -w '%{http_code}' "https://$EXPECTED_HOST/")"
  if [[ "$public_code" != "200" ]] || ! grep -Fq 'Firecrawl API' "$public_body"; then
    echo "error: public Cloudflare request failed validation (HTTP $public_code)" >&2
    echo "Response body follows:" >&2
    cat "$public_body" >&2
    return 1
  fi
  echo "Cloudflare -> Tunnel -> Traefik -> Service -> API: HTTP 200 / Firecrawl API"

  echo
  echo "Firecrawl ingress path validation: OK"
  echo "No scrape/crawl job was submitted by this test."
}

case "$ACTION" in
  validate) validate ;;
  status) status ;;
  deploy) deploy ;;
  test) test_path ;;
  *)
    echo "Usage: $0 {validate|status|deploy|test}" >&2
    exit 2
    ;;
esac
