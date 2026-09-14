#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-${ROOT_DIR}/kubernetes/secrets/cloudflared-token.sops.yaml}"
NAMESPACE="cloudflare"
SECRET_NAME="cloudflared-tunnel-token"

command -v kubectl >/dev/null || { echo "ERROR: kubectl not found" >&2; exit 1; }
command -v sops >/dev/null || { echo "ERROR: sops not found" >&2; exit 1; }

TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
if [[ -z "${TOKEN}" ]]; then
  read -r -s -p "Cloudflare Tunnel token: " TOKEN
  echo
fi

[[ -n "${TOKEN}" ]] || { echo "ERROR: tunnel token is empty" >&2; exit 1; }

mkdir -p "$(dirname "${OUTPUT}")"
TMP="$(mktemp "${ROOT_DIR}/kubernetes/secrets/.cloudflared-token.XXXXXX.sops.yaml")"
trap 'rm -f "${TMP}"; unset TOKEN CLOUDFLARE_TUNNEL_TOKEN' EXIT

kubectl create secret generic "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --from-literal="token=${TOKEN}" \
  --dry-run=client \
  --output=yaml > "${TMP}"

(
  cd "${ROOT_DIR}"
  sops --encrypt --in-place "${TMP#${ROOT_DIR}/}"
)

mv "${TMP}" "${OUTPUT}"
chmod 0644 "${OUTPUT}"
trap - EXIT
unset TOKEN CLOUDFLARE_TUNNEL_TOKEN

echo "Encrypted Cloudflare Tunnel Secret written to: ${OUTPUT}"
echo "No plaintext Secret was persisted."
