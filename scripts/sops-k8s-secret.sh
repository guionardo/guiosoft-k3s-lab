#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-k8s-secret.sh edit <file.sops.yaml>
  scripts/sops-k8s-secret.sh view <file.sops.yaml>
  scripts/sops-k8s-secret.sh validate <file.sops.yaml>
  scripts/sops-k8s-secret.sh apply <file.sops.yaml>

The file must live below kubernetes/ and end with .sops.yaml.
EOF
}

ACTION="${1:-}"
FILE="${2:-}"

if [[ -z "$ACTION" || -z "$FILE" ]]; then
  usage >&2
  exit 2
fi

case "$ACTION" in
  edit|view|validate|apply) ;;
  *)
    usage >&2
    exit 2
    ;;
esac

case "$FILE" in
  kubernetes/*.sops.yaml|kubernetes/**/*.sops.yaml) ;;
  *)
    echo "Refusing file outside kubernetes/**/*.sops.yaml: $FILE" >&2
    exit 2
    ;;
esac

# Guard against path traversal while still allowing application-local encrypted
# manifests such as kubernetes/apps/firecrawl/firecrawl-secrets.sops.yaml.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
KUBERNETES_ROOT="$(realpath -m "$REPO_ROOT/kubernetes")"
ABS_FILE="$(realpath -m "$REPO_ROOT/$FILE")"
case "$ABS_FILE" in
  "$KUBERNETES_ROOT"/*) ;;
  *)
    echo "Refusing path outside repository kubernetes tree: $FILE" >&2
    exit 2
    ;;
esac

command -v sops >/dev/null 2>&1 || {
  echo "sops is not installed. Run: make tools" >&2
  exit 1
}

case "$ACTION" in
  edit)
    mkdir -p "$(dirname "$FILE")"
    exec sops "$FILE"
    ;;
  view)
    [[ -f "$FILE" ]] || { echo "File not found: $FILE" >&2; exit 1; }
    exec sops decrypt "$FILE"
    ;;
  validate)
    [[ -f "$FILE" ]] || { echo "File not found: $FILE" >&2; exit 1; }
    command -v kubectl >/dev/null 2>&1 || {
      echo "kubectl is not installed." >&2
      exit 1
    }
    sops decrypt "$FILE" | kubectl apply --dry-run=client -f - >/dev/null
    echo "Valid encrypted Kubernetes manifest: $FILE"
    ;;
  apply)
    [[ -f "$FILE" ]] || { echo "File not found: $FILE" >&2; exit 1; }
    command -v kubectl >/dev/null 2>&1 || {
      echo "kubectl is not installed." >&2
      exit 1
    }
    sops decrypt "$FILE" | kubectl apply -f -
    ;;
esac
