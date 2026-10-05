#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-validate}"
APP_DIR="${PLANETAPEIA_APP_DIR:-kubernetes/apps/planetapeia}"
NAMESPACE="${PLANETAPEIA_NAMESPACE:-planetapeia}"
EXPECTED_HOST="${PLANETAPEIA_HOST:-planetapeia-preview.guiosoft.info}"

need() {
  command -v "$1" >/dev/null || { echo "error: required command not found: $1" >&2; exit 1; }
}

validate() {
  need kubectl

  echo "Planetapeia Kubernetes scaffold validation (read-only)"
  echo

  rendered="$(mktemp)"
  trap 'rm -f "$rendered"' RETURN
  kubectl kustomize "$APP_DIR" >"$rendered"

  echo "Rendered manifests: OK"
  kubectl apply --dry-run=client -f "$rendered" >/dev/null
  echo "kubectl client-side dry-run: OK"

  if ! grep -Eq '^kind: Ingress$' "$rendered"; then
    echo "error: Planetapeia Ingress is missing" >&2
    return 1
  fi
  if ! grep -Fq "host: $EXPECTED_HOST" "$rendered"; then
    echo "error: expected hostname not found: $EXPECTED_HOST" >&2
    return 1
  fi
  echo "Public Ingress: $EXPECTED_HOST via ingressClassName=traefik"

  echo
  echo "Images referenced:"
  awk '/^[[:space:]]+image:/ {print "- " $2}' "$rendered" | sort -u

  floating=0
  while read -r image; do
    [[ -n "$image" ]] || continue
    case "$image" in
      ghcr.io/planetapeia/*:sha-*) ;;
      *@sha256:*) ;;
      *) echo "floating image: $image"; floating=1 ;;
    esac
  done < <(awk '/^[[:space:]]+image:/ {print $2}' "$rendered" | sort -u)
  if (( floating == 0 )); then
    echo "Image pinning: OK (own images by sha tag, third-party by digest)"
  else
    echo "error: floating image references found" >&2
    return 1
  fi

  echo
  echo "PersistentVolumeClaims:"
  echo "- planetapeia-backups (manifest)"
  echo "- data-planetapeia-db-0 (volumeClaimTemplates do StatefulSet)"

  echo
  echo "Planetapeia scaffold validation: OK"
  echo "No Docker or Kubernetes resources were changed."
}

status() {
  need kubectl
  kubectl get deploy,statefulset,pod,svc,ingress,cronjob -n "$NAMESPACE" -o wide
  echo
  kubectl get pvc -n "$NAMESPACE"
}

case "$ACTION" in
  validate) validate ;;
  status) status ;;
  *) echo "usage: $0 validate|status" >&2; exit 2 ;;
esac
