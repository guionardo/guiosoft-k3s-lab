#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-validate}"
APP_DIR="${FIRECRAWL_APP_DIR:-kubernetes/apps/firecrawl}"
NAMESPACE="${FIRECRAWL_NAMESPACE:-firecrawl}"

need() {
  command -v "$1" >/dev/null || { echo "error: required command not found: $1" >&2; exit 1; }
}

validate() {
  need kubectl

  echo "Firecrawl Kubernetes scaffold validation (read-only)"
  echo

  kubectl kustomize "$APP_DIR" >/tmp/firecrawl-k8s-rendered.yaml
  trap 'rm -f /tmp/firecrawl-k8s-rendered.yaml' RETURN

  echo "Rendered manifests: OK"
  kubectl apply --dry-run=client -f /tmp/firecrawl-k8s-rendered.yaml >/dev/null
  echo "kubectl client-side dry-run: OK"

  if grep -Eq '^kind: Ingress$' /tmp/firecrawl-k8s-rendered.yaml; then
    echo "error: base Firecrawl scaffold unexpectedly contains an Ingress" >&2
    return 1
  fi
  echo "Public Ingress in base scaffold: none"

  echo
  echo "Images referenced:"
  awk '/^[[:space:]]+image:/ {print "- " $2}' /tmp/firecrawl-k8s-rendered.yaml | sort -u

  echo
  echo "Floating image references that must be pinned before production cutover:"
  floating=0
  while read -r image; do
    [[ -n "$image" ]] || continue
    if [[ "$image" != *@sha256:* ]] && { [[ "$image" == *:latest ]] || [[ "${image##*/}" != *:* ]]; }; then
      echo "- $image"
      floating=1
    fi
  done < <(awk '/^[[:space:]]+image:/ {print $2}' /tmp/firecrawl-k8s-rendered.yaml | sort -u)
  if (( floating == 0 )); then
    echo "- none"
  fi

  echo
  echo "PersistentVolumeClaims:"
  awk '
    /^kind: PersistentVolumeClaim$/ { pvc=1; next }
    pvc && /^metadata:/ { next }
    pvc && /^[[:space:]]+name:/ { print "- " $2; pvc=0 }
  ' /tmp/firecrawl-k8s-rendered.yaml

  echo
  echo "Secret handling:"
  echo "- plaintext example only: $APP_DIR/secret.example.yaml"
  echo "- runtime secret name expected: firecrawl-secrets"
  echo "- create encrypted secret separately with SOPS + age before any real deployment"

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
  kubectl get deploy,svc,pvc -n "$NAMESPACE" -o wide
}

case "$ACTION" in
  validate) validate ;;
  status) status ;;
  *)
    echo "Usage: $0 {validate|status}" >&2
    exit 2
    ;;
esac
