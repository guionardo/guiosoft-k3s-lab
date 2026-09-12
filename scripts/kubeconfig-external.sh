#!/usr/bin/env bash
set -euo pipefail

command -v kubectl >/dev/null || { echo "error: kubectl not found" >&2; exit 1; }

ADDRESS="${K3S_EXTERNAL_ADDRESS:-}"

if [[ -z "$ADDRESS" ]]; then
  ADDRESS="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
fi

if [[ -z "$ADDRESS" ]]; then
  echo "error: unable to determine a node InternalIP; set K3S_EXTERNAL_ADDRESS explicitly" >&2
  exit 1
fi

case "$ADDRESS" in
  127.*|localhost|::1)
    echo "error: refusing loopback address '$ADDRESS'; use the server LAN address" >&2
    exit 1
    ;;
esac

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

kubectl config view --raw --flatten >"$TMP"

CLUSTER="$(kubectl --kubeconfig "$TMP" config view --minify -o jsonpath='{.contexts[0].context.cluster}')"
CURRENT_SERVER="$(kubectl --kubeconfig "$TMP" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
PORT="${K3S_EXTERNAL_PORT:-}"

if [[ -z "$PORT" ]]; then
  PORT="$(sed -E 's#^https?://[^:/]+:([0-9]+).*$#\1#' <<<"$CURRENT_SERVER")"
  [[ "$PORT" =~ ^[0-9]+$ ]] || PORT=6443
fi

kubectl --kubeconfig "$TMP" config set-cluster "$CLUSTER" \
  --server="https://${ADDRESS}:${PORT}" >/dev/null

echo "# WARNING: this kubeconfig contains cluster-admin credentials." >&2
echo "# Keep it private and do not commit it to Git." >&2
echo "# API endpoint: https://${ADDRESS}:${PORT}" >&2

cat "$TMP"
