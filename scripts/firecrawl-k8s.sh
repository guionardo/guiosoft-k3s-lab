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
  kubectl get deploy,svc,ingress -n "$NAMESPACE" -o wide
}

case "$ACTION" in
  validate) validate ;;
  status) status ;;
  *)
    echo "Usage: $0 {validate|status}" >&2
    exit 2
    ;;
esac
